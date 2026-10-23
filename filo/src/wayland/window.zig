const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const engine = @import("../engine.zig");
const windowing = @import("../windowing.zig");

/// What a configure of 0×0 means: the compositor is leaving the size to us.
const default_width = 800;
const default_height = 600;

/// The largest size a popup or content-sized window can ask the engine for.
pub const max_content_size = 4_096;

/// The scale factor reported to the engine. Wayland lets the compositor scale
/// the buffer we attach instead, which is what we rely on: the swapchain is
/// always as big as the engine drew. Fractional and integer buffer scale would
/// both mean drawing at a different size than we tell the engine.
const default_pixel_ratio = 1.5;

/// The xdg-shell role a surface has. Toplevels are regular windows, dialogs and
/// satellites; popups are tooltips and popups.
pub const Role = union(enum) {
    toplevel: *xdg.Toplevel,
    popup: *xdg.Popup,
};

/// One window: a surface and its xdg-shell role. The connection it lives on,
/// the engine it draws for, and the loop that drives it are owned elsewhere and
/// passed in where they are needed.
pub const Window = struct {
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    role: Role,

    configured: bool = false,
    /// Size the compositor last asked for, in surface (logical) pixels. Starts
    /// at the default because the initial configure may leave the size to us.
    width: u32 = default_width,
    height: u32 = default_height,
    pixel_ratio: f64 = default_pixel_ratio,
    /// Whether the platform should derive the surface size from the first
    /// rendered frame. Popups and sized-to-content windows set this.
    ///
    /// It is atomic because the raster thread checks it in `presentView` while
    /// the main thread may adopt the implicit view as sized-to-content.
    sized_to_content: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Whether later frame sizes should keep resizing the surface. For a
    /// resizable sized-to-content toplevel this is cleared after the initial
    /// size has been applied; a popup and a non-resizable window keep tracking.
    track_content_size: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    resizable: bool = true,
    /// Limits for engine metrics while tracking the content size. They are in
    /// the same units as the metrics event, i.e. physical pixels.
    content_min_width: u32 = 1,
    content_min_height: u32 = 1,
    content_max_width: u32 = max_content_size,
    content_max_height: u32 = max_content_size,
    /// Set by a configure that changed the size, drained by the event loop,
    /// which forwards it to the engine.
    resized: bool = false,
    /// A popup configure arrived. The event loop clears a pending content
    /// resize, even if the compositor kept the old size.
    popup_configured: bool = false,
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
    /// Popups: top-left corner relative to the parent client area.
    offset_from_parent: windowing.Offset = .{ .x = 0, .y = 0 },
    /// The compositor moved the popup since the last drain.
    offset_dirty: bool = false,
    /// The compositor dismissed the popup.
    popup_done: bool = false,
    /// The last positioner applied to a popup, so an update can change just the
    /// anchor rectangle.
    positioner: windowing.Positioner = std.mem.zeroes(windowing.Positioner),
    /// Token for the next `xdg_popup.reposition`.
    reposition_token: u32 = 0,

    /// Install a toplevel window on freshly created surface/xdg/toplevel
    /// proxies.
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
            .role = .{ .toplevel = toplevel },
        };
        xdg_surface.setListener(*Window, xdgSurfaceListener, self);
        toplevel.setListener(*Window, toplevelListener, self);
        surface.commit();
        return self;
    }

    /// Install a popup window on freshly created surface/xdg/popup proxies.
    pub fn createPopup(
        allocator: std.mem.Allocator,
        surface: *wl.Surface,
        xdg_surface: *xdg.Surface,
        popup: *xdg.Popup,
    ) !*Window {
        const self = try allocator.create(Window);
        self.* = .{
            .surface = surface,
            .xdg_surface = xdg_surface,
            .role = .{ .popup = popup },
        };
        xdg_surface.setListener(*Window, xdgSurfaceListener, self);
        popup.setListener(*Window, popupListener, self);
        surface.commit();
        return self;
    }

    pub fn destroy(self: *Window, allocator: std.mem.Allocator) void {
        switch (self.role) {
            .toplevel => |toplevel| toplevel.destroy(),
            .popup => |popup| popup.destroy(),
        }
        self.xdg_surface.destroy();
        self.surface.destroy();
        allocator.destroy(self);
    }

    pub fn isPopup(self: *const Window) bool {
        return switch (self.role) {
            .popup => true,
            .toplevel => false,
        };
    }

    /// Copy the sizing flags and bounds out of a windowing request.
    pub fn applyRequest(self: *Window, req: *const windowing.WindowRequest) void {
        const sized = req.sized_to_content != 0;
        self.resizable = req.resizable != 0;
        self.sized_to_content.store(sized, .release);
        self.track_content_size.store(sized, .release);
        self.setContentConstraints(req.min_size, req.max_size);
    }

    /// Update the limits used for engine metrics. A zero maximum means
    /// unbounded, matching the ABI's encoding.
    pub fn setContentConstraints(self: *Window, min: windowing.Size, max: windowing.Size) void {
        self.content_min_width = boundedMin(min.width);
        self.content_min_height = boundedMin(min.height);
        self.content_max_width = boundedMax(max.width, self.content_min_width);
        self.content_max_height = boundedMax(max.height, self.content_min_height);
    }

    pub fn isSizedToContent(self: *const Window) bool {
        return self.sized_to_content.load(.acquire);
    }

    pub fn isTrackingContentSize(self: *const Window) bool {
        return self.track_content_size.load(.acquire);
    }

    /// Bounds for the engine metrics event, or null for the normal tight case.
    pub fn metricsConstraints(self: *const Window) ?engine.WindowConstraints {
        if (!self.isTrackingContentSize()) return null;
        return .{
            .min_width = self.content_min_width,
            .min_height = self.content_min_height,
            .max_width = self.content_max_width,
            .max_height = self.content_max_height,
        };
    }

    /// Apply a size derived from a rendered frame to a toplevel. Popups get
    /// their size through `xdg_popup.reposition` instead.
    pub fn applyContentSize(self: *Window, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        if (!self.resizable) {
            const fixed = windowing.Size{ .width = width, .height = height };
            self.setMinSize(fixed);
            self.setMaxSize(fixed);
            self.commit();
        }
        self.resized = true;
    }

    fn boundedMin(value: u32) u32 {
        return @max(1, @min(value, max_content_size));
    }

    fn boundedMax(value: u32, min: u32) u32 {
        if (value == 0) return max_content_size;
        return @max(min, @min(value, max_content_size));
    }

    fn toplevelRole(self: *Window) ?*xdg.Toplevel {
        return switch (self.role) {
            .toplevel => |toplevel| toplevel,
            .popup => null,
        };
    }

    /// Queue the xdg_toplevel requests below. They are double-buffered, so the
    /// caller commits the surface (`commit`) once after a batch. They are
    /// no-ops for a popup, which has no such requests.
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        if (self.toplevelRole()) |toplevel| toplevel.setTitle(title);
    }

    pub fn setMinSize(self: *Window, size: windowing.Size) void {
        if (self.toplevelRole()) |toplevel| {
            toplevel.setMinSize(@intCast(size.width), @intCast(size.height));
        }
    }

    pub fn setMaxSize(self: *Window, size: windowing.Size) void {
        if (self.toplevelRole()) |toplevel| {
            toplevel.setMaxSize(@intCast(size.width), @intCast(size.height));
        }
    }

    pub fn setMaximized(self: *Window, maximized: bool) void {
        const toplevel = self.toplevelRole() orelse return;
        if (maximized) toplevel.setMaximized() else toplevel.unsetMaximized();
    }

    /// There is no unminimize request in core xdg-shell; the compositor decides
    /// how a minimized window is restored.
    pub fn setMinimized(self: *Window, minimized: bool) void {
        if (self.toplevelRole()) |toplevel| {
            if (minimized) toplevel.setMinimized();
        }
    }

    pub fn setFullscreen(self: *Window, fullscreen: bool) void {
        const toplevel = self.toplevelRole() orelse return;
        if (fullscreen) toplevel.setFullscreen(null) else toplevel.unsetFullscreen();
    }

    pub fn setParent(self: *Window, parent: ?*Window) void {
        const toplevel = self.toplevelRole() orelse return;
        toplevel.setParent(if (parent) |p| p.toplevelRole() else null);
    }

    /// Ask the compositor to reposition a popup. The new geometry arrives in
    /// the following `configure` event.
    pub fn reposition(self: *Window, positioner: *xdg.Positioner) void {
        switch (self.role) {
            .popup => |popup| {
                popup.reposition(positioner, self.reposition_token);
                self.reposition_token +%= 1;
            },
            .toplevel => {},
        }
    }

    /// Apply the queued xdg requests.
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

        std.debug.print("filo: view {} resized to {}x{}\n", .{ view_id, self.width, self.height });
        eng.sendWindowMetricsForView(view_id, self.width, self.height, self.pixel_ratio, self.metricsConstraints());
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
                if (size[0] == self.width and size[1] == self.height) {
                    // A non-resizable sized-to-content toplevel stopped
                    // tracking while it asked the compositor for the content
                    // size. A matching configure is the confirmation that lets
                    // it track later content changes again.
                    if (self.isSizedToContent() and !self.resizable) {
                        self.track_content_size.store(true, .release);
                    }
                    return;
                }

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

    fn popupListener(_: *xdg.Popup, event: xdg.Popup.Event, self: *Window) void {
        switch (event) {
            .configure => |configure| {
                self.popup_configured = true;
                self.offset_from_parent = .{ .x = configure.x, .y = configure.y };
                self.offset_dirty = true;

                const size = configuredSize(configure.width, configure.height) orelse return;
                if (size[0] == self.width and size[1] == self.height) return;

                self.width = size[0];
                self.height = size[1];
                self.resized = true;
            },
            // The compositor dismissed the popup; the client should destroy it.
            .popup_done => {
                std.debug.print("ASDLASHDAS\n", .{});
                self.popup_done = true;
            },
            // The following `configure` carries the new geometry.
            .repositioned => {},
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
