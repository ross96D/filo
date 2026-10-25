const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const zwlr = wayland.client.zwlr;

const engine = @import("../engine.zig");
const scale = @import("../scale.zig");
const windowing = @import("../windowing.zig");

/// What a configure of 0×0 means: the compositor is leaving the size to us.
const default_width = 800;
const default_height = 600;

/// The largest size a popup or content-sized window can ask the engine for.
pub const max_content_size = 4_096;

/// The fallback buffer scale before the compositor has reported one. The
/// connection replaces it with `wl_surface.preferred_buffer_scale`, or
/// `wl_output.scale` on compositors older than core Wayland 6.
pub const default_pixel_ratio: f64 = 1.0;

/// The role a surface has. Toplevels are regular windows, dialogs and
/// satellites; popups are tooltips and popups; a layer surface is the
/// wlr-layer-shell role (a bar, wallpaper, overlay, …).
pub const Role = union(enum) {
    toplevel: *xdg.Toplevel,
    popup: *xdg.Popup,
    layer: *zwlr.LayerSurfaceV1,
};

/// One window: a surface and its xdg-shell or layer-shell role. The connection
/// it lives on, the engine it draws for, and the loop that drives it are owned
/// elsewhere and passed in where they are needed.
pub const Window = struct {
    surface: *wl.Surface,
    /// Null for layer surfaces: wlr-layer-shell replaces xdg_surface.
    xdg_surface: ?*xdg.Surface = null,
    role: Role,

    /// The layer-surface properties last applied. The namespace pointer is not
    /// retained; only the double-buffered state is.
    layer_state: windowing.LayerSurface = std.mem.zeroes(windowing.LayerSurface),
    /// Layer surfaces are composited with premultiplied alpha, so panels and
    /// overlays can have transparent regions.
    transparent: bool = false,

    configured: bool = false,
    /// Size the compositor last asked for, in surface (logical) pixels. Starts
    /// at the default because the initial configure may leave the size to us.
    width: u32 = default_width,
    height: u32 = default_height,
    /// The integer factor between attached buffers and this surface-local size.
    /// Wayland surface-local coordinates stay logical; the engine is told
    /// `logical * pixel_ratio` physical pixels at this ratio.
    pixel_ratio: f64 = default_pixel_ratio,
    /// The compositor changed the buffer scale; the event loop resends metrics.
    scale_dirty: bool = false,
    /// The compositor sent a per-surface preferred buffer scale. It is more
    /// accurate than the output-wide fallback: it follows the surface between
    /// outputs.
    scale_from_compositor: bool = false,
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
    /// Limits for engine metrics while tracking the content size, in logical
    /// pixels. `metricsConstraints` converts them to physical pixels.
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
        surface.setListener(*Window, surfaceListener, self);
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
        surface.setListener(*Window, surfaceListener, self);
        surface.commit();
        return self;
    }

    /// Install a layer window on a freshly created surface and layer-surface
    /// proxy. The initial state and size are queued before the first commit,
    /// which is the commit the compositor answers with its first configure.
    pub fn createLayer(
        allocator: std.mem.Allocator,
        surface: *wl.Surface,
        layer_surface: *zwlr.LayerSurfaceV1,
        state: windowing.LayerSurface,
        width: u32,
        height: u32,
    ) !*Window {
        const self = try allocator.create(Window);
        self.* = .{
            .surface = surface,
            .role = .{ .layer = layer_surface },
            .width = width,
            .height = height,
            .transparent = true,
        };
        errdefer allocator.destroy(self);
        layer_surface.setListener(*Window, layerSurfaceListener, self);
        surface.setListener(*Window, surfaceListener, self);
        try self.writeLayerSurface(state);
        layer_surface.setSize(width, height);
        surface.commit();
        return self;
    }

    pub fn destroy(self: *Window, allocator: std.mem.Allocator) void {
        switch (self.role) {
            .toplevel => |toplevel| toplevel.destroy(),
            .popup => |popup| popup.destroy(),
            .layer => |layer| layer.destroy(),
        }
        if (self.xdg_surface) |xdg_surface| xdg_surface.destroy();
        self.surface.destroy();
        allocator.destroy(self);
    }

    pub fn isPopup(self: *const Window) bool {
        return switch (self.role) {
            .popup => true,
            .toplevel, .layer => false,
        };
    }

    pub fn isLayer(self: *const Window) bool {
        return switch (self.role) {
            .layer => true,
            .toplevel, .popup => false,
        };
    }

    pub fn layerRole(self: *Window) ?*zwlr.LayerSurfaceV1 {
        return switch (self.role) {
            .layer => |layer| layer,
            .toplevel, .popup => null,
        };
    }

    /// Queue a new layer-surface state and apply it with the next commit.
    pub fn applyLayerSurface(self: *Window, state: windowing.LayerSurface) !void {
        try self.writeLayerSurface(state);
        self.commit();
    }

    fn writeLayerSurface(self: *Window, state: windowing.LayerSurface) !void {
        const layer_surface = self.layerRole() orelse return error.NotALayerSurface;
        if (!layerSizeValid(state.anchor, self.width, self.height)) return error.InvalidSize;

        // `get_layer_surface` already assigned the layer at creation. The
        // request only exists from version 2 on.
        const layer = layerFromInt(state.layer) orelse return error.InvalidLayer;
        if (layer_surface.getVersion() >= 2) layer_surface.setLayer(layer);

        layer_surface.setAnchor(layerAnchor(state.anchor));
        layer_surface.setExclusiveZone(state.exclusive_zone);
        layer_surface.setMargin(
            state.margin_top,
            state.margin_right,
            state.margin_bottom,
            state.margin_left,
        );

        const interactivity = keyboardInteractivityFromInt(state.keyboard_interactivity) orelse
            return error.InvalidKeyboardInteractivity;
        // `on_demand` was added in version 4.
        if (interactivity == .on_demand and layer_surface.getVersion() < 4) {
            return error.UnsupportedKeyboardInteractivity;
        }
        layer_surface.setKeyboardInteractivity(interactivity);

        self.layer_state = state;
        self.layer_state.namespace = null;
    }

    /// Change the layer surface's requested size. The compositor may ignore it
    /// when the surface is anchored to opposite edges.
    pub fn setSize(self: *Window, size: windowing.Size) void {
        const layer_surface = self.layerRole() orelse return;
        self.width = size.width;
        self.height = size.height;
        layer_surface.setSize(size.width, size.height);
        self.resized = true;
        self.commit();
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

    /// Use `ratio` as the buffer scale. `wl_surface.set_buffer_scale` is
    /// integral and only exists from surface version 3; older compositors keep
    /// a 1:1 mapping. The request is applied by the raster thread with the
    /// first frame whose buffer size is a multiple of the new scale, so a scale
    /// change cannot commit an old, incompatible buffer.
    pub fn setPixelRatio(self: *Window, ratio: f64) void {
        const integer = scale.integral(ratio);
        if (self.surface.getVersion() < 3) return;

        const value: f64 = @floatFromInt(integer);
        if (self.pixel_ratio == value) return;

        self.pixel_ratio = value;
        self.scale_dirty = true;
    }

    /// The integer `wl_surface` buffer scale for the current ratio.
    pub fn bufferScale(self: *const Window) u32 {
        return scale.integral(self.pixel_ratio);
    }

    /// The attached buffer width in physical pixels.
    pub fn physicalWidth(self: *const Window) u32 {
        return scale.physical(self.width, self.pixel_ratio);
    }

    /// The attached buffer height in physical pixels.
    pub fn physicalHeight(self: *const Window) u32 {
        return scale.physical(self.height, self.pixel_ratio);
    }

    /// Bounds for the engine metrics event, or null for the normal tight case.
    /// The event is in physical pixels, while the stored limits are logical.
    pub fn metricsConstraints(self: *const Window) ?engine.WindowConstraints {
        if (!self.isTrackingContentSize()) return null;
        return .{
            .min_width = scale.physical(self.content_min_width, self.pixel_ratio),
            .min_height = scale.physical(self.content_min_height, self.pixel_ratio),
            .max_width = scale.physical(self.content_max_width, self.pixel_ratio),
            .max_height = scale.physical(self.content_max_height, self.pixel_ratio),
        };
    }

    /// Apply a size derived from a rendered frame to a toplevel or layer
    /// surface. Popups get their size through `xdg_popup.reposition` instead.
    pub fn applyContentSize(self: *Window, width: u32, height: u32) void {
        self.width = width;
        self.height = height;
        if (self.layerRole()) |layer_surface| {
            layer_surface.setSize(width, height);
            self.commit();
            self.resized = true;
            return;
        }
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
            .popup, .layer => null,
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
            .toplevel, .layer => {},
        }
    }

    /// Apply the queued xdg requests.
    pub fn commit(self: *Window) void {
        self.surface.commit();
    }

    /// Forward a size the compositor asked for to the engine, and/or new
    /// buffer-scale metrics, in the physical pixels the embedder ABI expects.
    /// The swapchain itself is not touched here: it follows the size the engine
    /// says it draws at (see `vulkan.Surface.acquire`), which is what the
    /// metrics below tell it, so there is nothing to hand over between threads.
    pub fn applyResize(self: *Window, eng: *engine.Engine, view_id: engine.ViewId) void {
        if (!self.resized and !self.scale_dirty) return;
        self.resized = false;
        self.scale_dirty = false;

        std.debug.print("filo: view {} resized to {}x{} logical at scale {d}\n", .{
            view_id,
            self.width,
            self.height,
            self.pixel_ratio,
        });
        eng.sendWindowMetricsForView(
            view_id,
            self.physicalWidth(),
            self.physicalHeight(),
            self.pixel_ratio,
            self.metricsConstraints(),
        );
        // A window metrics event makes the framework relayout and schedule a
        // frame on its own; asking for one anyway means a resize can never be
        // left unpainted.
        eng.scheduleFrame();
    }

    /// The compositor's per-surface buffer-scale preference. It is the
    /// documented source for HiDPI clients (core Wayland 6) and supersedes the
    /// output-wide `wl_output.scale` fallback, especially when a window moves
    /// between outputs with different scales.
    fn surfaceListener(_: *wl.Surface, event: wl.Surface.Event, self: *Window) void {
        switch (event) {
            .preferred_buffer_scale => |value| {
                if (value.factor <= 0) return;
                self.setPixelRatio(@floatFromInt(value.factor));
                self.scale_from_compositor = true;
            },
            else => {},
        }
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
                self.popup_done = true;
            },
            // The following `configure` carries the new geometry.
            .repositioned => {},
        }
    }

    /// A layer surface configure: acknowledge it, then adopt the size the
    /// compositor assigned. A zero dimension means the compositor left the
    /// choice to us, so the requested size stays in place.
    fn layerSurfaceListener(
        _: *zwlr.LayerSurfaceV1,
        event: zwlr.LayerSurfaceV1.Event,
        self: *Window,
    ) void {
        switch (event) {
            .configure => |configure| {
                const layer_surface = self.layerRole() orelse return;
                layer_surface.ackConfigure(configure.serial);

                var changed = false;
                if (configure.width != 0 and configure.width != self.width) {
                    self.width = configure.width;
                    changed = true;
                }
                if (configure.height != 0 and configure.height != self.height) {
                    self.height = configure.height;
                    changed = true;
                }
                if (changed) {
                    // The configure asks for a size the surface state has to
                    // match before the buffer for it can be attached. A zero
                    // dimension means the compositor left that axis to us, so
                    // repeat our current value.
                    layer_surface.setSize(self.width, self.height);
                    self.resized = true;
                }

                // Acknowledge the configure with the commit that follows it.
                self.surface.commit();
                self.configured = true;

                // A content-sized layer surface stops tracking while it asks
                // for its content size. A matching configure is the
                // confirmation that lets it track later content changes again.
                if (self.isSizedToContent() and !self.resizable and !changed) {
                    self.track_content_size.store(true, .release);
                }
            },
            // The compositor will not show this surface any more. Treat it as
            // a close request so the controller can destroy and recreate it.
            .closed => self.closing = true,
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

fn layerFromInt(value: i32) ?zwlr.LayerShellV1.Layer {
    return switch (value) {
        0 => .background,
        1 => .bottom,
        2 => .top,
        3 => .overlay,
        else => null,
    };
}

/// The ABI anchor bitmask and `zwlr_layer_surface_v1.anchor` share the same bit
/// values; mask off anything that is not one of the four edges.
fn layerAnchor(bits: u32) zwlr.LayerSurfaceV1.Anchor {
    return @bitCast(bits & (windowing.LayerAnchor.top |
        windowing.LayerAnchor.bottom |
        windowing.LayerAnchor.left |
        windowing.LayerAnchor.right));
}

fn keyboardInteractivityFromInt(value: i32) ?zwlr.LayerSurfaceV1.KeyboardInteractivity {
    return switch (value) {
        0 => .none,
        1 => .exclusive,
        2 => .on_demand,
        else => null,
    };
}

/// A zero layer-surface dimension is only legal when both opposite edges are
/// anchored: the compositor owns that dimension then.
pub fn layerSizeValid(anchor: u32, width: u32, height: u32) bool {
    const horizontal = anchor & (windowing.LayerAnchor.left | windowing.LayerAnchor.right) ==
        (windowing.LayerAnchor.left | windowing.LayerAnchor.right);
    const vertical = anchor & (windowing.LayerAnchor.top | windowing.LayerAnchor.bottom) ==
        (windowing.LayerAnchor.top | windowing.LayerAnchor.bottom);
    return (width != 0 or horizontal) and (height != 0 or vertical);
}

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

test "layer values map to the wlr-layer-shell enums" {
    const testing = std.testing;

    try testing.expectEqual(zwlr.LayerShellV1.Layer.background, layerFromInt(0).?);
    try testing.expectEqual(zwlr.LayerShellV1.Layer.bottom, layerFromInt(1).?);
    try testing.expectEqual(zwlr.LayerShellV1.Layer.top, layerFromInt(2).?);
    try testing.expectEqual(zwlr.LayerShellV1.Layer.overlay, layerFromInt(3).?);
    try testing.expectEqual(@as(?zwlr.LayerShellV1.Layer, null), layerFromInt(4));

    try testing.expectEqual(
        zwlr.LayerSurfaceV1.KeyboardInteractivity.none,
        keyboardInteractivityFromInt(0).?,
    );
    try testing.expectEqual(
        zwlr.LayerSurfaceV1.KeyboardInteractivity.on_demand,
        keyboardInteractivityFromInt(2).?,
    );
    try testing.expectEqual(@as(?zwlr.LayerSurfaceV1.KeyboardInteractivity, null), keyboardInteractivityFromInt(3));
}

test "layer anchor bits keep only the four edges" {
    const testing = std.testing;

    const bits: u32 = windowing.LayerAnchor.top |
        windowing.LayerAnchor.right |
        0xffff_fff0;
    try testing.expectEqual(
        @as(u32, windowing.LayerAnchor.top | windowing.LayerAnchor.right),
        @as(u32, @bitCast(layerAnchor(bits))),
    );
}

test "a zero layer dimension needs opposite anchors" {
    const testing = std.testing;
    const all: u32 = windowing.LayerAnchor.top |
        windowing.LayerAnchor.bottom |
        windowing.LayerAnchor.left |
        windowing.LayerAnchor.right;

    // Both dimensions fixed: any anchors are fine.
    try testing.expect(layerSizeValid(0, 320, 40));
    // Stretched horizontally and vertically.
    try testing.expect(layerSizeValid(all, 0, 0));
    // A zero width needs left and right; a zero height needs top and bottom.
    try testing.expect(!layerSizeValid(windowing.LayerAnchor.top, 0, 40));
    try testing.expect(!layerSizeValid(windowing.LayerAnchor.left, 320, 0));
    try testing.expect(layerSizeValid(windowing.LayerAnchor.left | windowing.LayerAnchor.right, 0, 40));
    try testing.expect(layerSizeValid(windowing.LayerAnchor.top | windowing.LayerAnchor.bottom, 320, 0));
}
