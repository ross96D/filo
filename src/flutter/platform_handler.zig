const std = @import("std");

const c = @import("flutter");
const engine = @import("../engine.zig");
const clipboard = @import("../clipboard.zig");
const codec = @import("codec.zig");

/// Handles `SystemChannels.platform`, the JSON method channel the framework
/// uses for the system clipboard, `SystemChrome`, `SystemSound`,
/// `SystemNavigator` and lifecycle notifications.
///
/// Only the clipboard and `SystemNavigator.pop` do anything; every other method
/// is acknowledged with a null success, which is exactly what the framework
/// expects from a shell that does not implement it (the channel is an
/// `OptionalMethodChannel`, so an error reply would surface as an exception).
pub const PlatformHandler = struct {
    allocator: std.mem.Allocator,
    eng: *engine.Engine,
    clipboard: *clipboard.Clipboard,
    /// Cleared by `SystemNavigator.pop` to leave the event loop.
    quit_flag: ?*bool = null,
    /// Response handle for an in-flight `Clipboard.getData`.
    pending_get: ?*const c.FlutterPlatformMessageResponseHandle = null,

    /// Register with the clipboard. Must be called once the handler is at its
    /// final address, because the callback keeps a pointer back to it.
    pub fn attach(self: *PlatformHandler) void {
        self.clipboard.on_receive = onClipboardReceive;
        self.clipboard.receive_ctx = self;
    }

    pub fn handlePlatformMessage(self: *PlatformHandler, message: *const c.FlutterPlatformMessage) void {
        const msg = message.*;
        var data: []const u8 = &.{};
        if (msg.message != null) data = msg.message[0..msg.message_size];
        self.handlePlatform(data, msg.response_handle);
    }

    fn handlePlatform(self: *PlatformHandler, data: []const u8, handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        }
        const method_val = root.object.get("method") orelse {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        };
        if (method_val != .string) {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        }
        const method = method_val.string;
        const args = root.object.get("args");

        if (std.mem.eql(u8, method, "Clipboard.setData")) {
            self.setData(args);
        } else if (std.mem.eql(u8, method, "Clipboard.getData")) {
            self.getData(handle, args);
            return;
        } else if (std.mem.eql(u8, method, "Clipboard.hasStrings")) {
            self.hasStrings(handle);
            return;
        } else if (std.mem.eql(u8, method, "SystemNavigator.pop")) {
            if (self.quit_flag) |flag| flag.* = false;
        }

        self.eng.sendPlatformMessageResponse(handle, codec.json_success);
    }

    /// `Clipboard.setData`, whose argument is a map with a `text` entry.
    fn setData(self: *PlatformHandler, args: ?std.json.Value) void {
        const a = args orelse return;
        if (a != .object) return;
        const text = a.object.get("text") orelse return;
        self.clipboard.setText(if (text == .string) text.string else "");
    }

    /// `Clipboard.getData`, whose argument is the requested MIME type. Only text
    /// is supported, matching the framework, which only ever asks for
    /// `text/plain`.
    fn getData(self: *PlatformHandler, handle: ?*const c.FlutterPlatformMessageResponseHandle, args: ?std.json.Value) void {
        if (args) |a| {
            if (a == .string and !clipboard.isTextMime(a.string)) {
                var buf: [128]u8 = undefined;
                self.eng.sendPlatformMessageResponse(handle, codec.jsonError(&buf, "error", "unsupported clipboard format"));
                return;
            }
        }

        // Nothing to read, or a transfer is already in flight: answer with a
        // null result, which the framework turns into a null `ClipboardData`.
        if (!self.clipboard.hasText() or self.clipboard.receive() == null) {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        }

        // The reply is sent from `onClipboardReceive`.
        self.pending_get = handle;
    }

    /// `Clipboard.hasStrings`, answered from the advertised MIME types without
    /// transferring anything.
    fn hasStrings(self: *PlatformHandler, handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        var buf: [32]u8 = undefined;
        const reply = std.fmt.bufPrint(&buf, "[{{\"value\":{s}}}]", .{
            if (self.clipboard.hasText()) "true" else "false",
        }) catch codec.json_success;
        self.eng.sendPlatformMessageResponse(handle, reply);
    }

    fn onClipboardReceive(ctx: ?*anyopaque, text: ?[]const u8) void {
        const self: *PlatformHandler = @ptrCast(@alignCast(ctx.?));
        const handle = self.pending_get orelse return;
        self.pending_get = null;

        const value = text orelse {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        };

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        appendGetDataReply(&out, self.allocator, value) catch {
            self.eng.sendPlatformMessageResponse(handle, codec.json_success);
            return;
        };
        self.eng.sendPlatformMessageResponse(handle, out.items);
    }
};

/// Build the `Clipboard.getData` success envelope, `[{"text": "..."}]`.
fn appendGetDataReply(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try out.appendSlice(gpa, "[{\"text\":");
    try codec.appendJsonString(out, gpa, text);
    try out.appendSlice(gpa, "}]");
}

test "clipboard get reply is a one-element list holding a text map" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);

    try appendGetDataReply(&out, gpa, "a\"b");
    try testing.expectEqualStrings("[{\"text\":\"a\\\"b\"}]", out.items);
}
