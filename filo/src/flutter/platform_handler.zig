const std = @import("std");

const ev = @import("zio").ev;

const c = @import("flutter");
const engine = @import("../engine.zig");
const clipboard = @import("../wayland/clipboard.zig");
const channels = @import("channels.zig");
const codec = @import("codec.zig");
const table = @import("table.zig");
const SystemSoundType = @import("types/system_sound.zig").SystemSoundType;
const AppExitType = @import("types/exit.zig").AppExitType;
const AppExitResponse = @import("types/exit.zig").AppExitResponse;

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
    /// Stopped when the framework asks to quit (`SystemNavigator.pop`).
    io: ?*ev.Loop = null,
    /// Response handle for an in-flight `Clipboard.getData`.
    pending_get: ?*const c.FlutterPlatformMessageResponseHandle = null,
    /// Method name → what to do with it.
    methods: table.Table(Method),

    /// The methods on this channel this embedder acts on. Everything else the
    /// framework sends here (SystemChrome, SystemSound, lifecycle
    /// notifications, ...) is only acknowledged.
    const Method = enum { set_data, get_data, has_strings, pop, play_sound, exit_app };

    const method_table = [_]table.Entry(Method){
        .{ .name = "Clipboard.setData", .value = .set_data },
        .{ .name = "Clipboard.getData", .value = .get_data },
        .{ .name = "Clipboard.hasStrings", .value = .has_strings },
        .{ .name = "SystemNavigator.pop", .value = .pop },
        .{ .name = "SystemSound.play", .value = .play_sound },
        .{ .name = "System.exitApplication", .value = .exit_app },
    };

    /// Build the method table. The clipboard callback is registered by `attach`,
    /// which has to run once the handler sits at its final address.
    pub fn init(
        allocator: std.mem.Allocator,
        eng: *engine.Engine,
        clipboard_ptr: *clipboard.Clipboard,
        io: ?*ev.Loop,
    ) PlatformHandler {
        return .{
            .allocator = allocator,
            .eng = eng,
            .clipboard = clipboard_ptr,
            .io = io,
            .methods = table.Table(Method).init(allocator, &method_table),
        };
    }

    pub fn deinit(self: *PlatformHandler) void {
        self.methods.deinit();
    }

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

    fn quit(self: *PlatformHandler) void {
        if (self.io) |io| io.stop();
    }

    fn handlePlatform(self: *PlatformHandler, data: []const u8, handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch return self.ack(handle.?);
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return self.ack(handle.?);
        const method_val = root.object.get("method") orelse return self.ack(handle.?);
        if (method_val != .string) return self.ack(handle.?);
        const method_name = method_val.string;
        const args = root.object.get("args") orelse codec.no_args;

        // Everything else the framework sends here (SystemChrome, SystemSound,
        // lifecycle notifications, ...) is only acknowledged.
        const method = self.methods.get(method_name) orelse return self.ack(handle.?);

        switch (method) {
            .set_data => if (clipboardText(args)) |text| self.clipboard.setText(text),
            .get_data => {
                self.getData(handle, clipboardFormat(args));
                return;
            },
            .has_strings => {
                self.hasStrings(handle);
                return;
            },
            .pop => self.quit(),
            .play_sound => {
                const soundType = SystemSoundType.fromString(args.string);
                std.debug.print("TODO: play system sound {}\n", .{soundType});
            },
            .exit_app => {
                const exit_type = AppExitType.fromString(args.object.get("type").?.string);
                const exit_code = args.object.get("exitCode").?.integer;
                std.debug.print("TODO: Use exit code when quiting {}\n", .{exit_code});
                switch (exit_type) {
                    .required => self.quit(),
                    .cancelable => {
                        var buffer: [128]u8 = @splat(0);
                        const formatted = std.mem.print(
                            &buffer,
                            "{{\"method\": \"System.requestAppExit\", \"args\": {{\"type\": \"{}\"}}}}",
                            .{exit_type},
                        ) catch unreachable;
                        self.eng.sendPlatformMessage(
                            channels.platform.name,
                            formatted,
                        );
                    },
                    .unknown => self.quit(),
                }
            },
        }
        self.ack(handle.?);
    }

    /// Acknowledge a message with a null success, the reply the framework
    /// expects from a shell that does not implement something: this channel is
    /// an `OptionalMethodChannel`, so an error would surface as an exception.
    fn ack(self: *PlatformHandler, handle: *const c.FlutterPlatformMessageResponseHandle) void {
        self.eng.sendPlatformMessageResponse(handle, codec.json_success);
    }

    /// `Clipboard.getData`: start a read for `format`, or fail if that is not a
    /// text format. A null format means the framework did not name one, which
    /// is the same as asking for text.
    fn getData(self: *PlatformHandler, handle: ?*const c.FlutterPlatformMessageResponseHandle, format: ?[]const u8) void {
        if (format) |mime| {
            if (!clipboard.isTextMime(mime)) {
                var buf: [128]u8 = undefined;
                self.eng.sendPlatformMessageResponse(handle, codec.jsonError(&buf, "error", "unsupported clipboard format"));
                return;
            }
        }

        // Nothing to read, or a transfer is already in flight: answer with a
        // null result, which the framework turns into a null `ClipboardData`.
        if (!self.clipboard.hasText() or !self.clipboard.receive()) {
            self.ack(handle.?);
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
            self.ack(handle);
            return;
        };

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
        appendGetDataReply(&out, self.allocator, value) catch {
            self.ack(handle);
            return;
        };
        self.eng.sendPlatformMessageResponse(handle, out.items);
    }
};

/// The argument of `Clipboard.setData`: a map whose only entry is the text to
/// put on the clipboard. `ClipboardData.text` is nullable and the framework
/// sends it as JSON null, which counts as an empty text; a message with no text
/// entry at all leaves the clipboard alone.
fn clipboardText(args: std.json.Value) ?[]const u8 {
    const map = switch (args) {
        .object => |map| map,
        else => return null,
    };
    const entry = map.get("text") orelse return null;
    return switch (entry) {
        .string => |text| text,
        else => "",
    };
}

/// The argument of `Clipboard.getData`: the requested format, as the bare
/// string the framework sends, or null when it did not name one. Only text is
/// supported, matching the framework, which only ever asks for `text/plain`.
fn clipboardFormat(args: std.json.Value) ?[]const u8 {
    return switch (args) {
        .string => |format| format,
        else => null,
    };
}

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
