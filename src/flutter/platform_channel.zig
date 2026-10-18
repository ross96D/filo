const std = @import("std");

const c = @import("flutter");
const engine = @import("../engine.zig");
const channels = @import("channels.zig");
const codec = @import("codec.zig");
const text_input = @import("text_input.zig");
const platform_handler = @import("platform_handler.zig");

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

    pub fn handle(self: *Registry, message: *const c.FlutterPlatformMessage) void {
        const eng = self.eng orelse return;
        const response_handle = message.response_handle;

        const name = std.mem.span(@as([*:0]const u8, @ptrCast(message.channel)));

        if (std.mem.eql(u8, name, channels.text_input.name)) {
            if (self.text_input) |ti| {
                ti.handlePlatformMessage(message);
            } else {
                var buf: [64]u8 = undefined;
                eng.sendPlatformMessageResponse(response_handle, codec.jsonError(&buf, "error", "text input not ready"));
            }
            return;
        }

        if (std.mem.eql(u8, name, channels.platform.name)) {
            if (self.platform) |handler| {
                handler.handlePlatformMessage(message);
            } else {
                var buf: [64]u8 = undefined;
                eng.sendPlatformMessageResponse(response_handle, codec.jsonError(&buf, "error", "platform handler not ready"));
            }
            return;
        }

        // Channels we do not implement still get an answer, encoded with their
        // own codec so the framework can decode it.
        eng.sendPlatformMessageResponse(response_handle, codec.defaultReply(channels.codecFor(name)));
    }
};
