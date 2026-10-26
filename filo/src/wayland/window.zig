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

/// The size a window starts with when the compositor leaves it to us.
pub const default_size = windowing.Size{ .width = default_width, .height = default_height };

/// The largest size a popup or content-sized window can ask the engine for.
pub const max_content_size = 4_096;

/// The fallback buffer scale before the compositor has reported one. The
/// connection replaces it with `wl_surface.preferred_buffer_scale`, or
/// `wl_output.scale` on compositors older than core Wayland 6.
pub const default_pixel_ratio: f64 = 1.0;

/// Bit for [Window.content_axes]: the width follows the rendered content.
pub const content_axis_width: u8 = 1 << 0;
/// Bit for [Window.content_axes]: the height follows the rendered content.
pub const content_axis_height: u8 = 1 << 1;

/// One window: a surface and its xdg-shell or layer-shell role. The connection
/// it lives on, the engine it draws for, and the loop that drives it are owned
/// elsewhere and passed in where they are needed.
pub const Window = struct {
    surface: *wl.Surface,
    role: Role,

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
    /// Which axes follow the size of the rendered content. A layer surface
    /// anchored to opposite edges has that axis owned by the compositor and
    /// does not track it. Zero means the window is not sized to content.
    ///
    /// It is atomic because the raster thread reads it in `presentView` while
    /// the main thread can stop content sizing after the initial frame.
    content_axes: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
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
    /// Set when the compositor asks the window to close.
    closing: bool = false,

    /// The role a surface has. Each variant owns everything that only makes
    /// sense for it: the xdg surface, popup positioner, layer-shell state, and
    /// the events waiting to be drained for that role.
    pub const Role = union(enum) {
        toplevel: Toplevel,
        popup: Popup,
        layer: Layer,
    };

    /// Toplevels are regular windows, dialogs and satellites.
    pub const Toplevel = struct {
        xdg_surface: *xdg.Surface,
        toplevel: *xdg.Toplevel,
        /// Bitmask of `windowing.ToplevelState`; several may be set at once.
        state_bits: u32 = 0,
        /// The compositor sent a new state set since the last drain.
        state_dirty: bool = false,
        /// Bitmask of `windowing.WmCapabilities`.
        wm_capabilities: u32 = 0,
        /// The compositor sent new capabilities since the last drain.
        capabilities_dirty: bool = false,

        pub fn toplevelState(self: *const Toplevel) u32 {
            return self.state_bits;
        }

        pub fn wmCapabilities(self: *const Toplevel) u32 {
            return self.wm_capabilities;
        }

        /// Queue the xdg_toplevel requests below. They are double-buffered, so
        /// the caller commits the surface once after a batch.
        pub fn setTitle(self: *Toplevel, title: [*:0]const u8) void {
            self.toplevel.setTitle(title);
        }

        pub fn setMinSize(self: *Toplevel, size: windowing.Size) void {
            self.toplevel.setMinSize(@intCast(size.width), @intCast(size.height));
        }

        pub fn setMaxSize(self: *Toplevel, size: windowing.Size) void {
            self.toplevel.setMaxSize(@intCast(size.width), @intCast(size.height));
        }

        pub fn setMaximized(self: *Toplevel, maximized: bool) void {
            if (maximized) self.toplevel.setMaximized() else self.toplevel.unsetMaximized();
        }

        /// There is no unminimize request in core xdg-shell; the compositor
        /// decides how a minimized window is restored.
        pub fn setMinimized(self: *Toplevel, minimized: bool) void {
            if (minimized) self.toplevel.setMinimized();
        }

        pub fn setFullscreen(self: *Toplevel, fullscreen: bool) void {
            if (fullscreen) self.toplevel.setFullscreen(null) else self.toplevel.unsetFullscreen();
        }

        pub fn setParent(self: *Toplevel, parent: ?*Toplevel) void {
            self.toplevel.setParent(if (parent) |p| p.toplevel else null);
        }
    };

    /// Popups are tooltips, menus and other transient surfaces.
    pub const Popup = struct {
        xdg_surface: *xdg.Surface,
        popup: *xdg.Popup,
        /// Top-left corner relative to the parent client area.
        offset: windowing.Offset = .{ .x = 0, .y = 0 },
        /// The compositor moved the popup since the last drain.
        offset_dirty: bool = false,
        /// A configure arrived since the last drain.
        configure_seen: bool = false,
        /// The compositor dismissed the popup.
        done: bool = false,
        /// The last positioner applied to the popup, so an update can change
        /// just the anchor rectangle.
        positioner: windowing.Positioner = std.mem.zeroes(windowing.Positioner),
        /// Token for the next `xdg_popup.reposition`.
        reposition_token: u32 = 0,

        pub fn offsetFromParent(self: *const Popup) windowing.Offset {
            return self.offset;
        }

        /// Ask the compositor to reposition the popup. The new geometry arrives
        /// in the following `configure` event.
        pub fn reposition(self: *Popup, positioner: *xdg.Positioner) void {
            self.popup.reposition(positioner, self.reposition_token);
            self.reposition_token +%= 1;
        }
    };

    /// Layer surfaces are the wlr-layer-shell role (a bar, wallpaper, overlay,
    /// …). They are composited with premultiplied alpha, so panels and overlays
    /// can have transparent regions.
    pub const Layer = struct {
        layer_surface: *zwlr.LayerSurfaceV1,
        /// The layer-surface properties last applied. The namespace pointer is
        /// not retained; only the double-buffered state is.
        state: windowing.LayerSurface = std.mem.zeroes(windowing.LayerSurface),
    };

    /// Install a window on freshly created Wayland proxies. For a layer
    /// surface the initial state and size are queued before the first commit,
    /// which is the commit the compositor answers with its first configure.
    pub fn create(
        allocator: std.mem.Allocator,
        surface: *wl.Surface,
        role: Role,
        size: windowing.Size,
    ) !*Window {
        const self = try allocator.create(Window);
        errdefer allocator.destroy(self);
        self.* = .{
            .surface = surface,
            .role = role,
            .width = size.width,
            .height = size.height,
        };

        switch (self.role) {
            .toplevel => |toplevel| {
                toplevel.xdg_surface.setListener(*Window, xdgSurfaceListener, self);
                toplevel.toplevel.setListener(*Window, toplevelListener, self);
            },
            .popup => |popup| {
                popup.xdg_surface.setListener(*Window, xdgSurfaceListener, self);
                popup.popup.setListener(*Window, popupListener, self);
            },
            .layer => |layer| {
                layer.layer_surface.setListener(*Window, layerSurfaceListener, self);
                try self.writeLayerSurface(layer.state);
                layer.layer_surface.setSize(size.width, size.height);
            },
        }
        surface.setListener(*Window, surfaceListener, self);
        surface.commit();
        return self;
    }

    pub fn destroy(self: *Window, allocator: std.mem.Allocator) void {
        switch (self.role) {
            .toplevel => |toplevel| {
                toplevel.toplevel.destroy();
                toplevel.xdg_surface.destroy();
            },
            .popup => |popup| {
                popup.popup.destroy();
                popup.xdg_surface.destroy();
            },
            .layer => |layer| layer.layer_surface.destroy(),
        }
        self.surface.destroy();
        allocator.destroy(self);
    }

    /// Queue a new layer-surface state and apply it with the next commit. The
    /// caller must have checked the window's role.
    pub fn applyLayerSurface(self: *Window, state: windowing.LayerSurface) !void {
        try self.writeLayerSurface(state);
        self.commit();
    }

    fn writeLayerSurface(self: *Window, state: windowing.LayerSurface) !void {
        std.debug.assert(self.role == .layer);
        const layer = &self.role.layer;
        if (!layerSizeValid(state.anchor, self.width, self.height)) return error.InvalidSize;

        // `get_layer_surface` already assigned the layer at creation. The
        // request only exists from version 2 on.
        const shell_layer = layerFromInt(state.layer) orelse return error.InvalidLayer;
        if (layer.layer_surface.getVersion() >= 2) layer.layer_surface.setLayer(shell_layer);

        layer.layer_surface.setAnchor(layerAnchor(state.anchor));
        layer.layer_surface.setExclusiveZone(state.exclusive_zone);
        layer.layer_surface.setMargin(
            state.margin_top,
            state.margin_right,
            state.margin_bottom,
            state.margin_left,
        );

        const interactivity = keyboardInteractivityFromInt(state.keyboard_interactivity) orelse
            return error.InvalidKeyboardInteractivity;
        // `on_demand` was added in version 4.
        if (interactivity == .on_demand and layer.layer_surface.getVersion() < 4) {
            return error.UnsupportedKeyboardInteractivity;
        }
        layer.layer_surface.setKeyboardInteractivity(interactivity);

        layer.state = state;
        layer.state.namespace = null;
    }

    /// Change the layer surface's requested size. The compositor may ignore it
    /// when the surface is anchored to opposite edges.
    ///
    /// A zero request for a stretched axis is not a zero surface size: the
    /// compositor keeps choosing it, so the cached size stays at the last
    /// configured value.
    pub fn requestLayerSize(self: *Window, size: windowing.Size) void {
        const layer = &self.role.layer;
        const anchors = layer.state.anchor;
        if (!stretchesWidth(anchors)) self.width = size.width;
        if (!stretchesHeight(anchors)) self.height = size.height;
        layer.layer_surface.setSize(size.width, size.height);
        self.resized = true;
        self.commit();
    }

    /// Copy the sizing flags and bounds out of a windowing request.
    ///
    /// For a layer surface, an axis anchored to both opposite edges is owned
    /// by the compositor. Content sizing only applies to the remaining axes.
    pub fn applyRequest(self: *Window, req: *const windowing.WindowRequest) void {
        const sized = req.sized_to_content != 0;
        self.resizable = req.resizable != 0;

        // A layer request carries the authoritative anchors, even when the
        // surface itself has not been reconfigured yet (hot restart).
        const anchors = switch (self.role) {
            .layer => req.layer_surface.anchor,
            .toplevel, .popup => 0,
        };
        var axes: u8 = 0;
        if (sized) {
            if (!stretchesWidth(anchors)) axes |= content_axis_width;
            if (!stretchesHeight(anchors)) axes |= content_axis_height;
        }
        self.content_axes.store(axes, .release);
        self.setContentConstraints(req.min_size, req.max_size);
    }

    /// Stop deriving this window's size from its content. Used once a
    /// resizable sized-to-content toplevel has completed its initial size, and
    /// when the caller explicitly requests a size.
    pub fn stopSizingToContent(self: *Window) void {
        self.content_axes.store(0, .release);
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
        return self.content_axes.load(.acquire) != 0;
    }

    pub fn tracksContentWidth(self: *const Window) bool {
        return self.content_axes.load(.acquire) & content_axis_width != 0;
    }

    pub fn tracksContentHeight(self: *const Window) bool {
        return self.content_axes.load(.acquire) & content_axis_height != 0;
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
    ///
    /// A content-sized axis gets the request's bounds so the framework can
    /// choose a new content size. An axis owned by the compositor (a stretched
    /// layer surface) stays tight, so the framework fills the configured size
    /// on that axis.
    pub fn metricsConstraints(self: *const Window) ?engine.WindowConstraints {
        const axes = self.content_axes.load(.acquire);
        if (axes == 0) return null;

        const physical_width = self.physicalWidth();
        const physical_height = self.physicalHeight();
        return .{
            .min_width = if (axes & content_axis_width != 0)
                scale.physical(self.content_min_width, self.pixel_ratio)
            else
                physical_width,
            .min_height = if (axes & content_axis_height != 0)
                scale.physical(self.content_min_height, self.pixel_ratio)
            else
                physical_height,
            .max_width = if (axes & content_axis_width != 0)
                scale.physical(self.content_max_width, self.pixel_ratio)
            else
                physical_width,
            .max_height = if (axes & content_axis_height != 0)
                scale.physical(self.content_max_height, self.pixel_ratio)
            else
                physical_height,
        };
    }

    /// Apply a size derived from a rendered frame to a toplevel or layer
    /// surface. Popups get their size through `xdg_popup.reposition` instead.
    ///
    /// Only content-sized axes are updated; a layer axis owned by the
    /// compositor keeps its configured size.
    pub fn applyContentSize(self: *Window, width: u32, height: u32) void {
        const axes = self.content_axes.load(.acquire);
        if (axes & content_axis_width != 0) self.width = width;
        if (axes & content_axis_height != 0) self.height = height;

        switch (self.role) {
            .layer => |*layer| {
                // A stretched axis is owned by the compositor: request zero so
                // it keeps choosing that dimension.
                const anchors = layer.state.anchor;
                layer.layer_surface.setSize(
                    if (stretchesWidth(anchors)) 0 else self.width,
                    if (stretchesHeight(anchors)) 0 else self.height,
                );
                self.commit();
                self.resized = true;
                return;
            },
            .toplevel => |*toplevel| {
                if (!self.resizable) {
                    const fixed = windowing.Size{ .width = self.width, .height = self.height };
                    toplevel.setMinSize(fixed);
                    toplevel.setMaxSize(fixed);
                    self.commit();
                }
            },
            .popup => {},
        }
        self.resized = true;
    }

    /// Apply an explicit size requested through the windowing API. This leaves
    /// content-sizing mode and asks the engine to draw at the requested size.
    pub fn applyRequestedSize(self: *Window, size: windowing.Size) void {
        self.stopSizingToContent();
        self.width = size.width;
        self.height = size.height;
        if (!self.resizable) {
            switch (self.role) {
                .toplevel => |*toplevel| {
                    toplevel.setMinSize(size);
                    toplevel.setMaxSize(size);
                },
                .popup, .layer => {},
            }
            self.commit();
        }
        self.resized = true;
    }

    /// Clamp the cached size to the current content constraints. Used after a
    /// constraint update so the next metrics event stays valid even before the
    /// compositor confirms the new native size.
    pub fn clampToContentConstraints(self: *Window) void {
        const axes = self.content_axes.load(.acquire);
        if (axes & content_axis_width != 0) {
            self.width = std.math.clamp(self.width, self.content_min_width, self.content_max_width);
        }
        if (axes & content_axis_height != 0) {
            self.height = std.math.clamp(self.height, self.content_min_height, self.content_max_height);
        }
    }

    fn boundedMin(value: u32) u32 {
        return @max(1, @min(value, max_content_size));
    }

    fn boundedMax(value: u32, min: u32) u32 {
        if (value == 0) return max_content_size;
        return @max(min, @min(value, max_content_size));
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
        const toplevel = &self.role.toplevel;
        switch (event) {
            .configure => |configure| {
                const bits = stateBits(configure.states);
                if (bits != toplevel.state_bits) {
                    toplevel.state_bits = bits;
                    toplevel.state_dirty = true;
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
                if (bits != toplevel.wm_capabilities) {
                    toplevel.wm_capabilities = bits;
                    toplevel.capabilities_dirty = true;
                }
            },
            else => {},
        }
    }

    fn popupListener(_: *xdg.Popup, event: xdg.Popup.Event, self: *Window) void {
        const popup = &self.role.popup;
        switch (event) {
            .configure => |configure| {
                popup.configure_seen = true;
                popup.offset = .{ .x = configure.x, .y = configure.y };
                popup.offset_dirty = true;

                const size = configuredSize(configure.width, configure.height) orelse return;
                if (size[0] == self.width and size[1] == self.height) return;

                self.width = size[0];
                self.height = size[1];
                self.resized = true;
            },
            // The compositor dismissed the popup; the client should destroy it.
            .popup_done => {
                popup.done = true;
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
        const layer = &self.role.layer;
        switch (event) {
            .configure => |configure| {
                layer.layer_surface.ackConfigure(configure.serial);

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
                    layer.layer_surface.setSize(self.width, self.height);
                    self.resized = true;
                }

                // Acknowledge the configure with the commit that follows it.
                self.surface.commit();
                self.configured = true;
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

fn stretchesWidth(anchor: u32) bool {
    return anchor & (windowing.LayerAnchor.left | windowing.LayerAnchor.right) ==
        (windowing.LayerAnchor.left | windowing.LayerAnchor.right);
}

fn stretchesHeight(anchor: u32) bool {
    return anchor & (windowing.LayerAnchor.top | windowing.LayerAnchor.bottom) ==
        (windowing.LayerAnchor.top | windowing.LayerAnchor.bottom);
}

/// A zero layer-surface dimension is only legal when both opposite edges are
/// anchored: the compositor owns that dimension then.
pub fn layerSizeValid(anchor: u32, width: u32, height: u32) bool {
    return (width != 0 or stretchesWidth(anchor)) and
        (height != 0 or stretchesHeight(anchor));
}

test "role state queries read the owning variant" {
    const testing = std.testing;

    var toplevel: Window.Toplevel = .{ .xdg_surface = undefined, .toplevel = undefined };
    toplevel.state_bits = windowing.ToplevelState.activated;
    toplevel.wm_capabilities = windowing.WmCapabilities.maximize;
    try testing.expectEqual(windowing.ToplevelState.activated, toplevel.toplevelState());
    try testing.expectEqual(windowing.WmCapabilities.maximize, toplevel.wmCapabilities());

    var popup: Window.Popup = .{ .xdg_surface = undefined, .popup = undefined };
    popup.offset = .{ .x = 12, .y = -3 };
    const offset = popup.offsetFromParent();
    try testing.expectEqual(@as(i32, 12), offset.x);
    try testing.expectEqual(@as(i32, -3), offset.y);
}

test "content-sized metrics stay loose per content axis" {
    const testing = std.testing;

    var win: Window = undefined;
    win.pixel_ratio = 2;
    win.width = 320;
    win.height = 40;
    win.content_min_width = 100;
    win.content_min_height = 10;
    win.content_max_width = 900;
    win.content_max_height = 90;

    win.content_axes.store(content_axis_width | content_axis_height, .release);
    const both = win.metricsConstraints().?;
    try testing.expectEqual(@as(usize, 200), both.min_width);
    try testing.expectEqual(@as(usize, 1800), both.max_width);
    try testing.expectEqual(@as(usize, 20), both.min_height);
    try testing.expectEqual(@as(usize, 180), both.max_height);

    // Only the height is content-sized; the width stays tight at the current
    // compositor-assigned size (320 logical -> 640 physical).
    win.content_axes.store(content_axis_height, .release);
    const height_only = win.metricsConstraints().?;
    try testing.expectEqual(@as(usize, 640), height_only.min_width);
    try testing.expectEqual(@as(usize, 640), height_only.max_width);
    try testing.expectEqual(@as(usize, 20), height_only.min_height);
    try testing.expectEqual(@as(usize, 180), height_only.max_height);

    win.content_axes.store(0, .release);
    try testing.expect(win.metricsConstraints() == null);
}

test "content sizing only tracks layer axes the compositor does not own" {
    const testing = std.testing;

    var win: Window = undefined;
    var req = std.mem.zeroes(windowing.WindowRequest);
    req.sized_to_content = 1;
    req.layer_surface.anchor = windowing.LayerAnchor.left | windowing.LayerAnchor.right;

    win.role = .{ .layer = .{ .layer_surface = undefined } };
    win.applyRequest(&req);
    try testing.expect(!win.tracksContentWidth());
    try testing.expect(win.tracksContentHeight());
    try testing.expect(win.isSizedToContent());

    // A toplevel has no layer anchors, so it tracks both axes.
    win.role = .{ .toplevel = .{ .xdg_surface = undefined, .toplevel = undefined } };
    win.applyRequest(&req);
    try testing.expect(win.tracksContentWidth());
    try testing.expect(win.tracksContentHeight());

    // Both axes stretched: nothing is content-sized.
    win.role = .{ .layer = .{ .layer_surface = undefined } };
    req.layer_surface.anchor = windowing.LayerAnchor.top |
        windowing.LayerAnchor.bottom |
        windowing.LayerAnchor.left |
        windowing.LayerAnchor.right;
    win.applyRequest(&req);
    try testing.expect(!win.isSizedToContent());
}

test "stopping content sizing clears the axes" {
    const testing = std.testing;

    var win: Window = undefined;
    win.content_axes = std.atomic.Value(u8).init(content_axis_width | content_axis_height);

    win.stopSizingToContent();
    try testing.expect(!win.isSizedToContent());
}

test "an explicit size leaves content sizing" {
    const testing = std.testing;

    var win: Window = undefined;
    win.content_axes = std.atomic.Value(u8).init(content_axis_width | content_axis_height);
    win.resizable = true;

    win.applyRequestedSize(.{ .width = 500, .height = 300 });
    try testing.expectEqual(@as(u32, 500), win.width);
    try testing.expectEqual(@as(u32, 300), win.height);
    try testing.expect(!win.isSizedToContent());
    try testing.expect(win.resized);
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
