const std = @import("std");

const c = @import("flutter");
const xkb = @import("xkb");
const engine = @import("../engine.zig");
const channels = @import("channels.zig");
const codec = @import("codec.zig");

const KEY_RETURN: u32 = @intCast(xkb.XKB_KEY_Return);
const KEY_KP_ENTER: u32 = @intCast(xkb.XKB_KEY_KP_Enter);
const KEY_ISO_ENTER: u32 = @intCast(xkb.XKB_KEY_ISO_Enter);

/// Implements the `flutter/textinput` platform channel, speaking the
/// `JSONMethodCodec` protocol the framework expects (see `TextInput` in the
/// framework's services/text_input.dart).
///
/// Editing keys (backspace/delete/arrows/home/end) are intentionally *not*
/// handled here: the framework's `DefaultTextEditingShortcuts` handles them
/// from the key events we send. The framework explicitly delegates space and
/// enter to the text input (`_commonShortcuts` in
/// default_text_editing_shortcuts.dart), and never inserts printable
/// characters itself, so those are the only edits we perform.
///
/// Offsets are treated as byte offsets into the UTF-8 buffer. This matches
/// Flutter's UTF-16 code-unit offsets only for BMP/ASCII text; proper UTF-16
/// handling is a TODO.
pub const TextInput = struct {
    allocator: std.mem.Allocator,
    eng: *engine.Engine,
    has_client: bool = false,
    client_id: i64 = 0,
    text: std.ArrayListUnmanaged(u8) = .empty,
    selection_base: i64 = 0,
    selection_extent: i64 = 0,
    multiline: bool = false,
    read_only: bool = false,
    action: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator, eng: *engine.Engine) TextInput {
        return .{ .allocator = allocator, .eng = eng };
    }

    pub fn deinit(self: *TextInput) void {
        self.text.deinit(self.allocator);
        self.action.deinit(self.allocator);
    }

    /// Entry point for messages on the `flutter/textinput` channel.
    pub fn handlePlatformMessage(self: *TextInput, message: *const c.FlutterPlatformMessage) void {
        const msg = message.*;
        var data: []const u8 = &.{};
        if (msg.message != null) data = msg.message[0..msg.message_size];
        self.handleTextInput(data, msg.response_handle);
    }

    fn handleTextInput(self: *TextInput, data: []const u8, handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            self.respondError(handle, "invalid json");
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            self.respondError(handle, "invalid message");
            return;
        }
        const method_val = root.object.get("method") orelse {
            self.respondError(handle, "missing method");
            return;
        };
        if (method_val != .string) {
            self.respondError(handle, "invalid method");
            return;
        }
        const method = method_val.string;
        const args = root.object.get("args");

        if (std.mem.eql(u8, method, "TextInput.setClient")) {
            self.setClient(args);
        } else if (std.mem.eql(u8, method, "TextInput.clearClient")) {
            self.clearClient();
        } else if (std.mem.eql(u8, method, "TextInput.setEditingState")) {
            self.setEditingState(args);
        } else if (std.mem.eql(u8, method, "TextInput.updateConfig")) {
            self.applyConfig(args);
        } else if (std.mem.eql(u8, method, "TextInput.show") or
            std.mem.eql(u8, method, "TextInput.hide") or
            std.mem.eql(u8, method, "TextInput.setEditableSizeAndTransform") or
            std.mem.eql(u8, method, "TextInput.setMarkedTextRect") or
            std.mem.eql(u8, method, "TextInput.setCaretRect") or
            std.mem.eql(u8, method, "TextInput.setSelectionRects") or
            std.mem.eql(u8, method, "TextInput.setStyle") or
            std.mem.eql(u8, method, "TextInput.requestAutofill") or
            std.mem.eql(u8, method, "TextInput.finishAutofillContext") or
            std.mem.eql(u8, method, "TextInput.setPlatformViewClient") or
            std.mem.eql(u8, method, "TextInput.startLiveTextInput"))
        {
            // Accepted no-ops.
        } else {
            self.respondError(handle, method);
            return;
        }

        self.eng.sendPlatformMessageResponse(handle, codec.json_success);
    }

    fn setClient(self: *TextInput, args: ?std.json.Value) void {
        const a = args orelse return;
        if (a != .array or a.array.items.len < 1) return;
        const id = a.array.items[0];
        if (id == .integer) self.client_id = id.integer;
        self.has_client = true;
        if (a.array.items.len >= 2) self.applyConfig(a.array.items[1]);
    }

    fn clearClient(self: *TextInput) void {
        self.has_client = false;
        self.client_id = 0;
        self.text.clearRetainingCapacity();
        self.selection_base = 0;
        self.selection_extent = 0;
    }

    fn applyConfig(self: *TextInput, config: ?std.json.Value) void {
        const cfg = config orelse return;
        if (cfg != .object) return;
        if (cfg.object.get("readOnly")) |v| {
            if (v == .bool) self.read_only = v.bool;
        }
        if (cfg.object.get("inputType")) |it| {
            const name: ?[]const u8 = switch (it) {
                .object => if (it.object.get("name")) |n| (if (n == .string) n.string else null) else null,
                .string => it.string,
                else => null,
            };
            if (name) |n| self.multiline = std.mem.indexOf(u8, n, "multiline") != null;
        }
        if (cfg.object.get("inputAction")) |act| {
            if (act == .string) {
                self.action.clearRetainingCapacity();
                self.action.appendSlice(self.allocator, act.string) catch {};
            }
        }
    }

    fn setEditingState(self: *TextInput, args: ?std.json.Value) void {
        const a = args orelse return;
        if (a != .object) return;
        if (a.object.get("text")) |t| {
            if (t == .string) {
                self.text.clearRetainingCapacity();
                self.text.appendSlice(self.allocator, t.string) catch {};
            }
        }
        self.selection_base = jsonInt(a.object, "selectionBase", self.selection_base);
        self.selection_extent = jsonInt(a.object, "selectionExtent", self.selection_extent);
    }

    /// Feed a key press to the active text input client.
    pub fn handleKey(self: *TextInput, keysym: u32, codepoint: u32, pressed: bool) void {
        if (!pressed or !self.has_client or self.read_only) return;

        if (keysym == KEY_RETURN or keysym == KEY_KP_ENTER or keysym == KEY_ISO_ENTER) {
            if (self.multiline) self.insertBytes("\n");
            self.performAction();
            return;
        }

        if (codepoint >= 0x20 and codepoint != 0x7f) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
            self.insertBytes(buf[0..n]);
        }
    }

    fn insertBytes(self: *TextInput, bytes: []const u8) void {
        const len = self.text.items.len;
        var base = clampOffset(self.selection_base, len);
        var extent = clampOffset(self.selection_extent, len);
        if (base > extent) std.mem.swap(usize, &base, &extent);

        self.text.replaceRange(self.allocator, base, extent - base, bytes) catch return;
        const caret: i64 = @intCast(base + bytes.len);
        self.selection_base = caret;
        self.selection_extent = caret;
        self.sendEditingState();
    }

    fn performAction(self: *TextInput) void {
        const action = if (self.action.items.len > 0) self.action.items else "TextInputAction.done";
        const gpa = self.allocator;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);

        out.appendSlice(gpa, "{\"method\":\"TextInputClient.performAction\",\"args\":[") catch return;
        codec.appendNum(&out, gpa, self.client_id) catch return;
        out.appendSlice(gpa, ",\"") catch return;
        out.appendSlice(gpa, action) catch return;
        out.appendSlice(gpa, "\"]}") catch return;

        self.eng.sendPlatformMessage(channels.text_input.name.ptr, out.items);
    }

    fn sendEditingState(self: *TextInput) void {
        const gpa = self.allocator;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);

        out.appendSlice(gpa, "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[") catch return;
        codec.appendNum(&out, gpa, self.client_id) catch return;
        out.appendSlice(gpa, ",{\"text\":") catch return;
        codec.appendJsonString(&out, gpa, self.text.items) catch return;
        out.appendSlice(gpa, ",\"selectionBase\":") catch return;
        codec.appendNum(&out, gpa, self.selection_base) catch return;
        out.appendSlice(gpa, ",\"selectionExtent\":") catch return;
        codec.appendNum(&out, gpa, self.selection_extent) catch return;
        out.appendSlice(gpa, ",\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false,\"composingBase\":-1,\"composingExtent\":-1}]}") catch return;

        self.eng.sendPlatformMessage(channels.text_input.name.ptr, out.items);
    }

    fn respondError(self: *TextInput, handle: ?*const c.FlutterPlatformMessageResponseHandle, what: []const u8) void {
        var message_buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "{s} not implemented", .{what}) catch "not implemented";
        var envelope_buf: [256]u8 = undefined;
        self.eng.sendPlatformMessageResponse(handle, codec.jsonError(&envelope_buf, "error", message));
    }
};

fn clampOffset(offset: i64, len: usize) usize {
    if (offset <= 0) return 0;
    const u: usize = @intCast(offset);
    return if (u > len) len else u;
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8, default: i64) i64 {
    if (obj.get(key)) |v| {
        if (v == .integer) return v.integer;
    }
    return default;
}

test "setClient, insert, and enter" {
    const testing = std.testing;
    testReset();

    var eng = testEngine();
    var ti = TextInput.init(testing.allocator, &eng);
    defer ti.deinit();

    feed(
        &ti,
        "{\"method\":\"TextInput.setClient\",\"args\":[42," ++
            "{\"inputType\":{\"name\":\"TextInputType.text\"},\"inputAction\":\"TextInputAction.done\"}]}",
    );
    try testing.expectEqualStrings("[null]", testResponded());

    testReset();

    // A printable key inserts at the caret and reports the new editing state.
    ti.handleKey('a', 'a', true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[42," ++
            "{\"text\":\"a\",\"selectionBase\":1,\"selectionExtent\":1," ++
            "\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false," ++
            "\"composingBase\":-1,\"composingExtent\":-1}]}",
        testSent(),
    );

    // Enter on a non-multiline field performs the action instead of inserting.
    testReset();
    ti.handleKey(@intCast(xkb.XKB_KEY_Return), 0, true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.performAction\",\"args\":[42,\"TextInputAction.done\"]}",
        testSent(),
    );
}

test "quote is escaped and selection is replaced" {
    const testing = std.testing;
    testReset();

    var eng = testEngine();
    var ti = TextInput.init(testing.allocator, &eng);
    defer ti.deinit();

    feed(&ti, "{\"method\":\"TextInput.setClient\",\"args\":[7,{\"inputType\":{\"name\":\"TextInputType.text\"}}]}");
    feed(&ti, "{\"method\":\"TextInput.setEditingState\",\"args\":{\"text\":\"hello\",\"selectionBase\":0,\"selectionExtent\":5}}");

    testReset();
    ti.handleKey('"', '"', true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[7," ++
            "{\"text\":\"\\\"\",\"selectionBase\":1,\"selectionExtent\":1," ++
            "\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false," ++
            "\"composingBase\":-1,\"composingExtent\":-1}]}",
        testSent(),
    );
}

fn testEngine() engine.Engine {
    var eng: engine.Engine = undefined;
    eng.handle = null;
    eng.procs = std.mem.zeroes(c.FlutterEngineProcTable);
    eng.procs.SendPlatformMessage = &testSendPlatformMessage;
    eng.procs.SendPlatformMessageResponse = &testSendResponse;
    return eng;
}

var test_sent_buf: [1024]u8 = undefined;
var test_sent_len: usize = 0;
var test_responded_buf: [1024]u8 = undefined;
var test_responded_len: usize = 0;

fn testReset() void {
    test_sent_len = 0;
    test_responded_len = 0;
}

fn testSent() []const u8 {
    return test_sent_buf[0..test_sent_len];
}

fn testResponded() []const u8 {
    return test_responded_buf[0..test_responded_len];
}

fn testAppend(buf: *[1024]u8, len: *usize, data: []const u8) void {
    const n = @min(data.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], data[0..n]);
    len.* += n;
}

fn testSendPlatformMessage(_: c.FlutterEngine, message: [*c]const c.FlutterPlatformMessage) callconv(.c) c.FlutterEngineResult {
    const msg = message.*;
    if (msg.message != null) testAppend(&test_sent_buf, &test_sent_len, msg.message[0..msg.message_size]);
    return 0;
}

fn testSendResponse(_: c.FlutterEngine, _: ?*const c.FlutterPlatformMessageResponseHandle, data: [*c]const u8, len: usize) callconv(.c) c.FlutterEngineResult {
    if (data != null) testAppend(&test_responded_buf, &test_responded_len, data[0..len]);
    return 0;
}

fn feed(ti: *TextInput, json: []const u8) void {
    var msg: c.FlutterPlatformMessage = undefined;
    msg.struct_size = @sizeOf(c.FlutterPlatformMessage);
    msg.channel = channels.text_input.name.ptr;
    msg.message = json.ptr;
    msg.message_size = json.len;
    msg.response_handle = @ptrFromInt(1);
    ti.handlePlatformMessage(&msg);
}
