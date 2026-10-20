const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const engine = @import("engine.zig");

/// What a configure of 0×0 means: the compositor is leaving the size to us.
const default_width = 800;
const default_height = 600;

/// The scale factor reported to the engine. Wayland lets the compositor scale
/// the buffer we attach instead, which is what we rely on: the swapchain is
/// always as big as the engine drew. Fractional and integer buffer scale would
/// both mean drawing at a different size than we tell the engine.
const default_pixel_ratio = 1.5;

/// One toplevel window: a surface and its xdg-shell state. The connection it
/// lives on, the engine it draws for, and the loop that drives it are owned
/// elsewhere and passed in where they are needed.
pub const Window = struct {
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,

    configured: bool = false,
    /// Size the compositor last asked for, in surface (logical) pixels. Starts
    /// at the default because the initial configure may leave the size to us.
    width: u32 = default_width,
    height: u32 = default_height,
    pixel_ratio: f64 = default_pixel_ratio,
    /// Set by a configure that changed the size, drained by the event loop,
    /// which forwards it to the engine.
    resized: bool = false,
    /// Set when the compositor asks the window to close.
    closing: bool = false,

    /// Install a window on freshly created surface/xdg/toplevel proxies.
    pub fn create(
        allocator: std.mem.Allocator,
        surface: *wl.Surface,
        xdg_surface: *xdg.Surface,
        toplevel: *xdg.Toplevel,
    ) !*Window {
        const self = try allocator.create(Window);
        self.* = .{
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
        };
        xdg_surface.setListener(*Window, xdgSurfaceListener, self);
        toplevel.setListener(*Window, toplevelListener, self);
        surface.commit();
        return self;
    }

    pub fn destroy(self: *Window, allocator: std.mem.Allocator) void {
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        allocator.destroy(self);
    }

    /// Forward a size the compositor asked for to the engine. The swapchain
    /// itself is not touched here: it follows the size the engine says it draws
    /// at (see `vulkan.Surface.acquire`), which is what the metrics below tell
    /// it, so there is nothing to hand over between threads.
    pub fn applyResize(self: *Window, eng: *engine.Engine) void {
        if (!self.resized) return;
        self.resized = false;

        std.debug.print("fembed: window resized to {}x{}\n", .{ self.width, self.height });
        eng.sendWindowMetrics(self.width, self.height, self.pixel_ratio);
        // A window metrics event makes the framework relayout and schedule a
        // frame on its own; asking for one anyway means a resize can never be
        // left unpainted.
        eng.scheduleFrame();
    }

    fn xdgSurfaceListener(xdg_surface: *xdg.Surface, event: xdg.Surface.Event, self: *Window) void {
        switch (event) {
            .configure => |configure| {
                xdg_surface.ackConfigure(configure.serial);
                self.surface.commit();
                self.configured = true;
            },
        }
    }

    fn toplevelListener(_: *xdg.Toplevel, event: xdg.Toplevel.Event, self: *Window) void {
        switch (event) {
            .configure => |configure| {
                // An unchanged size needs nothing: the engine was told the same
                // size already, and any rebuild it owes is driven by the size it
                // reports per frame.
                const size = configuredSize(configure.width, configure.height) orelse return;
                if (size[0] == self.width and size[1] == self.height) return;

                self.width = size[0];
                self.height = size[1];
                self.resized = true;
            },
            .close => self.closing = true,
            else => {},
        }
    }

    /// The size a configure is asking for, or null when it leaves the choice to
    /// us: a zero (or negative, which no compositor should send) width or
    /// height means exactly that.
    fn configuredSize(width: i32, height: i32) ?[2]u32 {
        if (width <= 0 or height <= 0) return null;
        return .{ @intCast(width), @intCast(height) };
    }
};

test "a configure that leaves the size to us is not a resize" {
    const testing = std.testing;

    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(0, 0));
    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(0, 600));
    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(800, 0));
    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(-1, 1080));
    try testing.expectEqual(@as(?[2]u32, .{ 1024, 768 }), Window.configuredSize(1024, 768));
}
