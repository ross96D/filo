const std = @import("std");

const c = @import("flutter");
const engine = @import("../engine.zig");
const channels = @import("channels.zig");
const codec = @import("codec.zig");
const types = @import("types/mouse_cursor.zig");

pub const Cursor = types.Cursor;

/// Handles the `flutter/mousecursor` method channel.
///
/// The framework sends `activateSystemCursor` with the pointer device and the
/// `SystemMouseCursors` name; this handler turns that into the shape the
/// Wayland backend should show. Like `WindowManager`, it only decodes the
/// message and hands the actual Wayland work to the main thread.
pub const MouseCursor = struct {
    eng: *engine.Engine,
    user_data: ?*anyopaque,
    set: *const fn (user_data: ?*anyopaque, cursor: Cursor) void,

    pub fn handlePlatformMessage(self: *MouseCursor, message: *const c.FlutterPlatformMessage) void {
        var data: []const u8 = &.{};
        if (message.message != null) data = message.message[0..message.message_size];

        if (types.decode(data)) |cursor| self.set(self.user_data, cursor);

        // The framework awaits this call from its mouse tracker. Always answer
        // with a standard success, including for malformed or unknown messages,
        // so a decoding difference cannot surface as an exception in the app.
        self.eng.sendPlatformMessageResponse(message.response_handle, codec.standard_method_success);
    }
};

var test_responded_buf: [32]u8 = undefined;
var test_responded_len: usize = 0;

fn testReset() void {
    test_responded_len = 0;
}

fn testResponded() []const u8 {
    return test_responded_buf[0..test_responded_len];
}

fn testSendResponse(_: c.FlutterEngine, _: ?*const c.FlutterPlatformMessageResponseHandle, data: [*c]const u8, len: usize) callconv(.c) c.FlutterEngineResult {
    if (data != null) {
        const n = @min(len, test_responded_buf.len - test_responded_len);
        @memcpy(test_responded_buf[test_responded_len..][0..n], data[0..n]);
        test_responded_len += n;
    }
    return 0;
}

var test_cursor: ?Cursor = null;

fn testSetCursor(_: ?*anyopaque, cursor: Cursor) void {
    test_cursor = cursor;
}

fn testMessage(data: []const u8) c.FlutterPlatformMessage {
    return .{
        .struct_size = @sizeOf(c.FlutterPlatformMessage),
        .channel = channels.mouse_cursor.name,
        .message = data.ptr,
        .message_size = data.len,
        .response_handle = @ptrFromInt(1),
    };
}

test "activateSystemCursor sets the cursor and acknowledges with a standard success" {
    const testing = std.testing;

    var eng: engine.Engine = undefined;
    eng.handle = null;
    eng.procs = std.mem.zeroes(c.FlutterEngineProcTable);
    eng.procs.SendPlatformMessageResponse = &testSendResponse;

    var handler = MouseCursor{
        .eng = &eng,
        .user_data = null,
        .set = testSetCursor,
    };

    // `activateSystemCursor` with `{"device": 1, "kind": "click"}`, encoded by
    // StandardMethodCodec.
    const data = "\x07\x14activateSystemCursor" ++
        "\x0d\x02" ++
        "\x07\x06device\x03\x01\x00\x00\x00" ++
        "\x07\x04kind\x07\x05click";

    testReset();
    test_cursor = null;
    const message = testMessage(data);
    handler.handlePlatformMessage(&message);

    try testing.expectEqual(@as(?Cursor, Cursor{ .shape = .pointer }), test_cursor);
    try testing.expectEqualStrings("\x00\x00", testResponded());
}

test "a message that is not an activation is still acknowledged" {
    const testing = std.testing;
    var eng: engine.Engine = undefined;
    eng.handle = null;
    eng.procs = std.mem.zeroes(c.FlutterEngineProcTable);
    eng.procs.SendPlatformMessageResponse = &testSendResponse;

    var handler = MouseCursor{
        .eng = &eng,
        .user_data = null,
        .set = testSetCursor,
    };

    // A JSON method call, which would arrive if the channel were misconfigured.
    const data = "{\"method\":\"activateSystemCursor\"}";
    testReset();
    test_cursor = null;
    const message = testMessage(data);
    handler.handlePlatformMessage(&message);

    try testing.expectEqual(@as(?Cursor, null), test_cursor);
    try testing.expectEqualStrings("\x00\x00", testResponded());
}
