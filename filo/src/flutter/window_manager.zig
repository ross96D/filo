const std = @import("std");

const c = @import("flutter");
const engine = @import("../engine.zig");
const codec = @import("codec.zig");

/// Handles the `filo/windows` method channel. Window creation and destruction
/// happen on the Wayland/Vulkan thread, so this handler only parses the request
/// and hands it to `main` through the engine's main-task queue.
pub const WindowManager = struct {
    eng: *engine.Engine,
    user_data: ?*anyopaque,
    create: *const fn (user_data: ?*anyopaque, width: u32, height: u32) void,
    close: *const fn (user_data: ?*anyopaque, view_id: engine.ViewId) void,

    pub fn handlePlatformMessage(self: *WindowManager, message: *const c.FlutterPlatformMessage) void {
        const msg = message.*;
        var data: []const u8 = &.{};
        if (msg.message != null) data = msg.message[0..msg.message_size];
        self.handlePlatform(data, msg.response_handle);
    }

    fn handlePlatform(
        self: *WindowManager,
        data: []const u8,
        handle: ?*const c.FlutterPlatformMessageResponseHandle,
    ) void {
        var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, data, .{}) catch
            return self.ack(handle);
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return self.ack(handle);
        const method_value = root.object.get("method") orelse return self.ack(handle);
        if (method_value != .string) return self.ack(handle);
        const args = root.object.get("args");

        if (std.mem.eql(u8, method_value.string, "create")) {
            const width = intArg(args, "width") orelse 800;
            const height = intArg(args, "height") orelse 600;
            self.create(
                self.user_data,
                @intCast(std.math.clamp(width, 1, 16_384)),
                @intCast(std.math.clamp(height, 1, 16_384)),
            );
        } else if (std.mem.eql(u8, method_value.string, "close")) {
            const view_id = intArg(args, "viewId") orelse return self.ack(handle);
            self.close(self.user_data, @intCast(view_id));
        }

        self.ack(handle);
    }

    fn ack(self: *WindowManager, handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        self.eng.sendPlatformMessageResponse(handle, codec.json_success);
    }
};

fn intArg(args: ?std.json.Value, name: []const u8) ?i64 {
    const value = args orelse return null;
    if (value != .object) return null;
    const entry = value.object.get(name) orelse return null;
    return switch (entry) {
        .integer => |number| number,
        else => null,
    };
}

test "window channel arguments are read from the JSON method envelope" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        "{\"method\":\"create\",\"args\":{\"width\":320,\"height\":240}}",
        .{},
    );
    defer parsed.deinit();

    const args = parsed.value.object.get("args");
    try std.testing.expectEqual(@as(?i64, 320), intArg(args, "width"));
    try std.testing.expectEqual(@as(?i64, 240), intArg(args, "height"));
    try std.testing.expectEqual(@as(?i64, null), intArg(args, "title"));
}
