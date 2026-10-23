const std = @import("std");

const c = @import("flutter");
const engine = @import("../engine.zig");
const channels = @import("channels.zig");
const codec = @import("codec.zig");
const table = @import("table.zig");
const text_input = @import("text_input.zig");
const platform_handler = @import("platform_handler.zig");
const window_manager = @import("window_manager.zig");
const mouse_cursor = @import("mouse_cursor.zig");

/// Routes the platform messages the framework sends to the handler for their
/// channel.
///
/// The engine hands a single `user_data` pointer to both the renderer callbacks
/// and the platform message callback, so the callback itself lives at the call
/// site and delegates here. Every message must be answered or the engine leaks
/// its response handle.
pub const Registry = struct {
    eng: ?*engine.Engine = null,
    text_input: ?*text_input.TextInput = null,
    platform: ?*platform_handler.PlatformHandler = null,
    windows: ?*window_manager.WindowManager = null,
    mouse_cursor: ?*mouse_cursor.MouseCursor = null,
    /// Channel name → route, built from `channels.routes`.
    routes: table.CompiletimeTable(channels.Route),

    /// Build the routing table. The handlers are attached afterwards, by writing
    /// the fields: they need the engine, which does not exist yet at this point.
    pub fn init() Registry {
        return .{ .routes = table.CompiletimeTable(channels.Route).init(&channels.routes) };
    }

    pub fn deinit(self: *Registry) void {
        _ = self;
    }

    pub fn handle(self: *Registry, message: *const c.FlutterPlatformMessage) void {
        const eng = self.eng orelse return;
        const response_handle = message.response_handle;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(message.channel)));
        const route = self.routes.get(name) orelse channels.Route{};

        const handler = route.handler orelse {
            // Channels we do not implement still get an answer, encoded with
            // their own codec so the framework can decode it.
            eng.sendPlatformMessageResponse(response_handle, codec.defaultReply(route.codec));
            return;
        };

        switch (handler) {
            .text_input => {
                const ti = self.text_input orelse {
                    notReady(eng, route.codec, response_handle, "text input");
                    return;
                };
                ti.handlePlatformMessage(message);
            },
            .platform => {
                const platform = self.platform orelse {
                    notReady(eng, route.codec, response_handle, "platform handler");
                    return;
                };
                platform.handlePlatformMessage(message);
            },
            .windows => {
                const windows = self.windows orelse {
                    notReady(eng, route.codec, response_handle, "window manager");
                    return;
                };
                windows.handlePlatformMessage(message);
            },
            .mouse_cursor => {
                const cursor = self.mouse_cursor orelse {
                    notReady(eng, route.codec, response_handle, "mouse cursor handler");
                    return;
                };
                cursor.handlePlatformMessage(message);
            },
        }
    }
};

/// Answer a message whose handler has not been built yet: the engine can deliver
/// messages as soon as it runs, which is before `main` has attached every
/// handler.
fn notReady(
    eng: *engine.Engine,
    channel_codec: channels.Codec,
    handle: ?*const c.FlutterPlatformMessageResponseHandle,
    what: []const u8,
) void {
    // Only JSON method channels have an error envelope that the framework
    // reports verbatim. A standard-codec channel has to get a reply it can
    // decode, so acknowledge it as a success instead.
    if (channel_codec != .json_method) {
        eng.sendPlatformMessageResponse(handle, codec.defaultReply(channel_codec));
        return;
    }

    var message_buf: [64]u8 = undefined;
    const message = std.fmt.bufPrint(&message_buf, "{s} not ready", .{what}) catch "not ready";
    var envelope_buf: [128]u8 = undefined;
    eng.sendPlatformMessageResponse(handle, codec.jsonError(&envelope_buf, "error", message));
}

fn testMessage(channel: [*:0]const u8, json: []const u8) c.FlutterPlatformMessage {
    return .{
        .struct_size = @sizeOf(c.FlutterPlatformMessage),
        .channel = channel,
        .message = json.ptr,
        .message_size = json.len,
        .response_handle = @ptrFromInt(1),
    };
}

test "messages are routed by channel name and answered with that channel's codec" {
    const testing = std.testing;

    var eng: engine.Engine = undefined;
    eng.handle = null;
    eng.procs = std.mem.zeroes(c.FlutterEngineProcTable);
    eng.procs.SendPlatformMessageResponse = &testSendResponse;

    var registry = Registry.init();
    defer registry.deinit();
    registry.eng = &eng;

    var ti = text_input.TextInput.init(testing.allocator, &eng);
    defer ti.deinit();
    registry.text_input = &ti;

    // An implemented channel reaches its handler.
    var text_input_message = testMessage("flutter/textinput", "{\"method\":\"TextInput.show\"}");
    testReset();
    registry.handle(&text_input_message);
    try testing.expectEqualStrings("[null]", testResponded());

    // An unimplemented `JSONMethodCodec` channel is acknowledged with a JSON
    // null, which the framework can decode.
    var undo_message = testMessage("flutter/undomanager", "{\"method\":\"UndoManager.undo\"}");
    testReset();
    registry.handle(&undo_message);
    try testing.expectEqualStrings("[null]", testResponded());

    // Anything else speaks `StandardMethodCodec` by default.
    var bogus_message = testMessage("flutter/bogus", "{}");
    testReset();
    registry.handle(&bogus_message);
    try testing.expectEqualStrings("\x00\x00", testResponded());

    // A standard-codec handler that is not attached yet still gets a reply the
    // framework can decode; a JSON error envelope would make it throw.
    var cursor_message = testMessage("flutter/mousecursor", "");
    testReset();
    registry.handle(&cursor_message);
    try testing.expectEqualStrings("\x00\x00", testResponded());

    // A handler that is not attached is reported, rather than leaving the
    // engine's response handle unanswered.
    var platform_message = testMessage("flutter/platform", "{\"method\":\"Clipboard.hasStrings\"}");
    testReset();
    registry.handle(&platform_message);
    try testing.expectEqualStrings("[\"error\",\"platform handler not ready\",null]", testResponded());
}

var test_responded_buf: [256]u8 = undefined;
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
