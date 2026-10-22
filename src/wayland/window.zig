const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const engine = @import("../engine.zig");
const windowing = @import("../windowing.zig");

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
    /// Bitmask of `windowing.ToplevelState`; several may be set at once.
    state_bits: u32 = 0,
    /// The compositor sent a new state set since the last drain.
    state_dirty: bool = false,
    /// Bitmask of `windowing.WmCapabilities`.
    wm_capabilities: u32 = 0,
    /// The compositor sent new capabilities since the last drain.
    capabilities_dirty: bool = false,

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

    /// Queue the xdg_toplevel requests below. They are double-buffered, so the
    /// caller commits the surface (`commit`) once after a batch.
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        self.toplevel.setTitle(title);
    }

    pub fn setMinSize(self: *Window, size: windowing.Size) void {
        self.toplevel.setMinSize(@intCast(size.width), @intCast(size.height));
    }

    pub fn setMaxSize(self: *Window, size: windowing.Size) void {
        self.toplevel.setMaxSize(@intCast(size.width), @intCast(size.height));
    }

    pub fn setMaximized(self: *Window, maximized: bool) void {
        if (maximized) self.toplevel.setMaximized() else self.toplevel.unsetMaximized();
    }

    /// There is no unminimize request in core xdg-shell; the compositor decides
    /// how a minimized window is restored.
    pub fn setMinimized(self: *Window, minimized: bool) void {
        if (minimized) self.toplevel.setMinimized();
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        if (fullscreen) self.toplevel.setFullscreen(null) else self.toplevel.unsetFullscreen();
    }

    pub fn setParent(self: *Window, parent: ?*Window) void {
        self.toplevel.setParent(if (parent) |p| p.toplevel else null);
    }

    /// Apply the queued xdg_toplevel requests.
    pub fn commit(self: *Window) void {
        self.surface.commit();
    }

    /// Forward a size the compositor asked for to the engine. The swapchain
    /// itself is not touched here: it follows the size the engine says it draws
    /// at (see `vulkan.Surface.acquire`), which is what the metrics below tell
    /// it, so there is nothing to hand over between threads.
    pub fn applyResize(self: *Window, eng: *engine.Engine, view_id: engine.ViewId) void {
        if (!self.resized) return;
        self.resized = false;

        std.debug.print("fembed: view {} resized to {}x{}\n", .{ view_id, self.width, self.height });
        eng.sendWindowMetricsForView(view_id, self.width, self.height, self.pixel_ratio);
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
                const bits = stateBits(configure.states);
                if (bits != self.state_bits) {
                    self.state_bits = bits;
                    self.state_dirty = true;
                }

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
            .wm_capabilities => |caps| {
                const bits = capabilityBits(caps.capabilities);
                if (bits != self.wm_capabilities) {
                    self.wm_capabilities = bits;
                    self.capabilities_dirty = true;
                }
            },
            else => {},
        }
    }

    /// Decode the `xdg_toplevel.state` array into the ABI bitmask.
    fn stateBits(states: anytype) u32 {
        const raw = states.data orelse return 0;
        const values: [*]const u32 = @ptrCast(@alignCast(raw));
        var bits: u32 = 0;
        for (values[0 .. states.size / @sizeOf(u32)]) |value| {
            bits |= stateBit(value);
        }
        return bits;
    }

    /// One `xdg_toplevel.state` value. The Dart `FiloToplevelState` uses the
    /// same 1-based values, so `value n` is ABI bit `n - 1`.
    fn stateBit(value: u32) u32 {
        return switch (value) {
            1 => windowing.ToplevelState.maximized,
            2 => windowing.ToplevelState.fullscreen,
            3 => windowing.ToplevelState.resizing,
            4 => windowing.ToplevelState.activated,
            5 => windowing.ToplevelState.tiled_left,
            6 => windowing.ToplevelState.tiled_right,
            7 => windowing.ToplevelState.tiled_top,
            8 => windowing.ToplevelState.tiled_bottom,
            9 => windowing.ToplevelState.suspended,
            10 => windowing.ToplevelState.constrained_left,
            11 => windowing.ToplevelState.constrained_right,
            12 => windowing.ToplevelState.constrained_top,
            13 => windowing.ToplevelState.constrained_bottom,
            else => 0,
        };
    }

    /// Decode the `xdg_toplevel.wm_capabilities` array into the ABI bitmask.
    fn capabilityBits(capabilities: anytype) u32 {
        const raw = capabilities.data orelse return 0;
        const values: [*]const u32 = @ptrCast(@alignCast(raw));
        var bits: u32 = 0;
        for (values[0 .. capabilities.size / @sizeOf(u32)]) |value| {
            bits |= capabilityBit(value);
        }
        return bits;
    }

    fn capabilityBit(value: u32) u32 {
        return switch (value) {
            1 => windowing.WmCapabilities.window_menu,
            2 => windowing.WmCapabilities.maximize,
            3 => windowing.WmCapabilities.fullscreen,
            4 => windowing.WmCapabilities.minimize,
            else => 0,
        };
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

test "xdg_toplevel states map to the ABI bitmask" {
    const testing = std.testing;

    try testing.expectEqual(windowing.ToplevelState.maximized, Window.stateBit(1));
    try testing.expectEqual(windowing.ToplevelState.fullscreen, Window.stateBit(2));
    try testing.expectEqual(windowing.ToplevelState.activated, Window.stateBit(4));
    try testing.expectEqual(windowing.ToplevelState.constrained_bottom, Window.stateBit(13));
    // Unknown and out-of-range values contribute nothing.
    try testing.expectEqual(@as(u32, 0), Window.stateBit(0));
    try testing.expectEqual(@as(u32, 0), Window.stateBit(14));
}

test "wm capabilities map to the ABI bitmask" {
    const testing = std.testing;

    try testing.expectEqual(windowing.WmCapabilities.window_menu, Window.capabilityBit(1));
    try testing.expectEqual(windowing.WmCapabilities.maximize, Window.capabilityBit(2));
    try testing.expectEqual(windowing.WmCapabilities.fullscreen, Window.capabilityBit(3));
    try testing.expectEqual(windowing.WmCapabilities.minimize, Window.capabilityBit(4));
    try testing.expectEqual(@as(u32, 0), Window.capabilityBit(5));
}
