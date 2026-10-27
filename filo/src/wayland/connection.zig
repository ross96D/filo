const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;
const wp = wayland.client.wp;
const zwlr = wayland.client.zwlr;

const engine = @import("../engine.zig");
const input = @import("../input.zig");
const clipboard = @import("clipboard.zig");
const mouse_cursor = @import("../flutter/types/mouse_cursor.zig");
const window = @import("window.zig");
const windowing = @import("../windowing.zig");
const Context = @import("../context.zig").Context;

const OutputInfo = struct {
    name: u32,
    version: u32,
};

const Globals = struct {
    allocator: std.mem.Allocator,
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    seat_name: ?u32 = null,
    cursor_shape_manager_name: ?u32 = null,
    cursor_shape_manager_version: u32 = 0,
    /// Every output the registry advertised, in registry order.
    outputs: std.ArrayListUnmanaged(OutputInfo) = .empty,
    layer_shell_name: ?u32 = null,
    layer_shell_version: u32 = 0,
    activation_name: ?u32 = null,
    activation_version: u32 = 0,
};

/// The Wayland connection: the display, its global objects (compositor, xdg,
/// data device manager), the seat and its input devices and clipboard, and the
/// output whose mode is the display's refresh rate. One per process; it mints
/// any number of `Window`s.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,
    data_device_manager: *wl.DataDeviceManager,
    seat_name: u32,
    seat: ?*wl.Seat = null,
    /// Every bound `wl_output`, in registry order. The first one drives the
    /// display metrics and the frame clock; layer surfaces can target any.
    outputs: std.ArrayListUnmanaged(*wl.Output) = .empty,
    /// The compositor's wlr-layer-shell implementation, if it advertises one.
    layer_shell: ?*zwlr.LayerShellV1 = null,
    /// The compositor's xdg-activation support, if it advertises the global.
    /// Without it, activation requests fall back to the compositor's policy.
    activation: ?*xdg.ActivationV1 = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    /// The compositor's cursor-shape-v1 support, if it advertises the global.
    /// Without it the named cursor requests are ignored, but `none` can still
    /// hide the pointer through `wl_pointer.set_cursor`.
    cursor_shape_manager: ?*wp.CursorShapeManagerV1 = null,
    cursor_shape_device: ?*wp.CursorShapeDeviceV1 = null,
    /// The last `wl_pointer.enter` serial: the only serial `set_shape` accepts.
    pointer_enter_serial: ?u32 = null,
    /// The most recent input serial. `xdg_popup.grab` needs one from the input
    /// event that opened the popup.
    last_serial: ?u32 = null,
    /// The shape the framework last asked for, re-applied on pointer enter.
    cursor: ?mouse_cursor.Cursor = null,
    cursor_shape_warned: bool = false,
    /// The engine-facing input and clipboard handlers, wired by `bindSeat`.
    input: ?*input.Input = null,
    clipboard: ?*clipboard.Clipboard = null,
    /// The output's current mode, for `FlutterEngineNotifyDisplayUpdate` and
    /// the frame clock.
    display_width: u32 = 0,
    display_height: u32 = 0,
    refresh_mhz: u32 = 0,
    frame_period_ns: u64 = engine.default_frame_period_ns,
    /// The output-wide integer buffer scale (`ceil` of its fractional scale),
    /// used as a fallback when the compositor does not send a per-surface
    /// `wl_surface.preferred_buffer_scale`. Windows render
    /// `logical * display_scale` pixels in that case.
    display_scale: u32 = 1,
    /// The compositor changed the output scale; the event loop applies it to
    /// every window.
    scale_dirty: bool = false,

    pub fn connect(allocator: std.mem.Allocator) !*Connection {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        errdefer registry.destroy();

        var globals = Globals{ .allocator = allocator };
        defer globals.outputs.deinit(allocator);
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoCompositor;
        const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
        const data_device_manager = globals.data_device_manager orelse return error.NoDataDeviceManager;
        const seat_name = globals.seat_name orelse return error.NoSeat;

        const self = try allocator.create(Connection);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .wm_base = wm_base,
            .data_device_manager = data_device_manager,
            .seat_name = seat_name,
        };

        // Bind every output. The first one's mode events are what the display
        // refreshes at and arrive on the roundtrips after this; the others are
        // only targets for layer surfaces.
        for (globals.outputs.items) |info| {
            const version = @min(info.version, wl.Output.generated_version);
            const output = registry.bind(info.name, wl.Output, version) catch continue;
            // Only the first output's mode events matter for the frame rate
            // and the display size; the others are layer-surface targets and
            // still need a listener so their events are dispatched.
            if (self.outputs.items.len == 0) {
                output.setListener(*Connection, outputListener, self);
            } else {
                output.setListener(*Connection, ignoreOutput, self);
            }
            self.outputs.append(allocator, output) catch {
                @as(*wl.Proxy, @ptrCast(output)).destroy();
                continue;
            };
        }

        if (globals.cursor_shape_manager_name) |name| {
            const version = @min(globals.cursor_shape_manager_version, wp.CursorShapeManagerV1.generated_version);
            self.cursor_shape_manager = registry.bind(name, wp.CursorShapeManagerV1, version) catch null;
        }

        if (globals.layer_shell_name) |name| {
            const version = @min(globals.layer_shell_version, zwlr.LayerShellV1.generated_version);
            self.layer_shell = registry.bind(name, zwlr.LayerShellV1, version) catch null;
        }

        if (globals.activation_name) |name| {
            const version = @min(globals.activation_version, xdg.ActivationV1.generated_version);
            self.activation = registry.bind(name, xdg.ActivationV1, version) catch null;
        }

        return self;
    }

    pub fn deinit(self: *Connection) void {
        if (self.clipboard) |clip| clip.deinit();
        if (self.cursor_shape_device) |device| device.destroy();
        if (self.cursor_shape_manager) |manager| manager.destroy();
        if (self.keyboard) |k| k.destroy();
        if (self.pointer) |p| p.destroy();
        for (self.outputs.items) |o| {
            // `release` needs version 3; below that the proxy is all there is.
            if (o.getVersion() >= 3) o.release() else @as(*wl.Proxy, @ptrCast(o)).destroy();
        }
        self.outputs.deinit(self.allocator);
        if (self.seat) |s| s.destroy();
        self.compositor.destroy();
        self.wm_base.destroy();
        if (self.layer_shell) |ls| {
            // `destroy` needs version 3; below that drop the proxy directly.
            if (ls.getVersion() >= 3) ls.destroy() else @as(*wl.Proxy, @ptrCast(ls)).destroy();
        }
        if (self.activation) |activation| activation.destroy();
        // `wl_data_device_manager` has no destructor below version 4, which is
        // all we bind, so drop the proxy directly.
        @as(*wl.Proxy, @ptrCast(self.data_device_manager)).destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    /// The fd the event loop watches for compositor events.
    pub fn getFd(self: *const Connection) std.posix.fd_t {
        return self.display.getFd();
    }

    /// Read and dispatch one batch of compositor events. Called by the event
    /// loop when the fd is readable, so the wait inside does not block.
    pub fn dispatch(self: *Connection) !void {
        if (self.display.prepareRead()) {
            const err = self.display.readEvents();
            if (err != .SUCCESS and err != .AGAIN) return error.DispatchFailed;
        }
        if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
    }

    /// Send any requests queued by the last dispatch.
    pub fn flush(self: *Connection) void {
        _ = self.display.flush();
    }

    pub fn roundtrip(self: *Connection) !void {
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }

    /// Create a toplevel window on this connection.
    pub fn createWindow(self: *Connection) !*window.Window {
        const surface = try self.compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try self.wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();

        return window.Window.create(
            self.allocator,
            surface,
            .{ .toplevel = .{
                .xdg_surface = xdg_surface,
                .toplevel = toplevel,
            } },
            window.default_size,
        );
    }

    /// Everything a layer window needs beyond the surface itself.
    pub const LayerOptions = struct {
        state: windowing.LayerSurface,
        /// Null lets the compositor choose which output to place it on.
        output: ?*wl.Output,
        /// Non-empty NUL-terminated namespace, e.g. "filo-bar".
        namespace: [*:0]const u8,
        /// Requested surface size; zero lets the compositor choose, which is
        /// only valid for dimensions anchored to opposite edges.
        width: u32,
        height: u32,
    };

    /// Create a wlr-layer-shell surface. Fails with `error.LayerShellUnavailable`
    /// when the compositor does not implement `zwlr_layer_shell_v1`.
    pub fn createLayer(self: *Connection, options: LayerOptions) !*window.Window {
        const layer_shell = self.layer_shell orelse return error.LayerShellUnavailable;

        const surface = try self.compositor.createSurface();
        errdefer surface.destroy();

        const layer: zwlr.LayerShellV1.Layer = switch (options.state.layer) {
            0 => .background,
            1 => .bottom,
            2 => .top,
            3 => .overlay,
            else => return error.InvalidLayer,
        };

        const layer_surface = try layer_shell.getLayerSurface(
            surface,
            options.output,
            layer,
            options.namespace,
        );
        errdefer layer_surface.destroy();

        // An empty input region makes the surface click-through. A null
        // region (the default) means the whole surface accepts input.
        try self.setSurfaceInputRegion(surface, options.state.accepts_input != 0);

        return window.Window.create(
            self.allocator,
            surface,
            .{ .layer = .{
                .layer_surface = layer_surface,
                .state = options.state,
            } },
            .{ .width = options.width, .height = options.height },
        );
    }

    /// Make a surface's input region empty (click-through) or restore the
    /// default whole-surface region. Applied by the next `wl_surface.commit`.
    pub fn setSurfaceInputRegion(self: *Connection, surface: *wl.Surface, accepts_input: bool) !void {
        if (accepts_input) {
            surface.setInputRegion(null);
            return;
        }
        const region = try self.compositor.createRegion();
        defer region.destroy();
        surface.setInputRegion(region);
    }

    /// Create a popup attached to `parent` and positioned by `positioner`. The
    /// positioner is only needed for this call; the caller may destroy it once
    /// this returns.
    pub fn createPopup(
        self: *Connection,
        parent: *window.Window,
        positioner: *xdg.Positioner,
    ) !*window.Window {
        const surface = try self.compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try self.wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const parent_xdg_surface: ?*xdg.Surface = switch (parent.role) {
            .toplevel => |toplevel| toplevel.xdg_surface,
            .popup => |popup| popup.xdg_surface,
            .layer => null,
        };
        const popup = try xdg_surface.getPopup(parent_xdg_surface, positioner);
        errdefer popup.destroy();

        // A layer surface is not an xdg_surface, so its popups are attached
        // through zwlr_layer_surface_v1.get_popup instead.
        switch (parent.role) {
            .layer => |layer| layer.layer_surface.getPopup(popup),
            .toplevel, .popup => {},
        }

        // A grab is what lets the compositor dismiss the popup on an outside
        // click. It needs the serial of the input event that opened it.
        if (self.seat) |seat| {
            if (self.last_serial) |serial| popup.grab(seat, serial);
        }

        return window.Window.create(
            self.allocator,
            surface,
            .{ .popup = .{
                .xdg_surface = xdg_surface,
                .popup = popup,
            } },
            window.default_size,
        );
    }

    /// Block until the compositor has sent the initial configure and the
    /// output's mode has been reported, so the surface is ready for buffers and
    /// the engine can be told the display it draws on.
    pub fn waitReady(self: *Connection, win: *window.Window) !void {
        while (!win.configured) try self.roundtrip();
        // The output's mode arrives in response to the bind, which happened
        // before this; one more roundtrip makes sure it has been dispatched.
        if (self.refresh_mhz == 0) try self.roundtrip();
        // Apply the buffer scale the compositor reported. The per-surface
        // preferred scale is authoritative; fall back to the output scale for
        // compositors older than core Wayland 6.
        if (!win.scale_from_compositor) win.setPixelRatio(@floatFromInt(self.display_scale));
        win.scale_dirty = false;
        // The caller creates the swapchain and sends the initial window metrics
        // from `width`/`height` right after this, so a configure that arrived
        // while we waited is already accounted for.
        win.resized = false;
    }

    /// Bind the seat and its keyboard/pointer/clipboard, and give them the
    /// engine-facing input handler.
    pub fn bindSeat(self: *Connection, ctx: *Context, inp: *input.Input) !void {
        self.input = inp;
        self.seat = try self.registry.bind(self.seat_name, wl.Seat, 8);
        self.seat.?.setListener(*Connection, seatListener, self);
        try self.roundtrip();

        self.clipboard = try clipboard.Clipboard.init(ctx, self.seat.?);
    }

    /// Show the cursor the framework last asked for. Call on the Wayland thread.
    pub fn setCursor(self: *Connection, cursor: mouse_cursor.Cursor) void {
        self.cursor = cursor;
        self.applyCursor();
    }

    fn applyCursor(self: *Connection) void {
        // `set_shape` and `set_cursor` only accept a serial from the latest
        // pointer enter. Requests that arrive while the pointer is elsewhere
        // stay stored and are applied on the next enter.
        const serial = self.pointer_enter_serial orelse return;
        const pointer = self.pointer orelse return;
        const cursor = self.cursor orelse return;

        switch (cursor) {
            .hidden => pointer.setCursor(serial, null, 0, 0),
            .shape => |shape| {
                const device = self.cursor_shape_device orelse {
                    if (!self.cursor_shape_warned) {
                        std.debug.print("filo: compositor has no wp_cursor_shape_manager_v1; ignoring cursor changes\n", .{});
                        self.cursor_shape_warned = true;
                    }
                    return;
                };
                device.setShape(serial, protocolShape(shape));
            },
        }
    }

    fn ignoreOutput(_: *wl.Output, _: wl.Output.Event, _: *Connection) void {}

    fn outputListener(_: *wl.Output, event: wl.Output.Event, self: *Connection) void {
        switch (event) {
            .mode => |mode| {
                // Modes that are not current are what the output *could* do.
                if (!mode.flags.current) return;
                if (mode.width <= 0 or mode.height <= 0) return;
                self.display_width = @intCast(mode.width);
                self.display_height = @intCast(mode.height);
                // Zero means the compositor does not know the refresh rate.
                if (mode.refresh <= 0) return;
                self.refresh_mhz = @intCast(mode.refresh);
                self.frame_period_ns = framePeriodNs(self.refresh_mhz);
            },
            .scale => |value| {
                // `wl_output.scale` is already the integer scale a client
                // should render at; compositors with fractional scaling send
                // its ceiling (1.5 -> 2) so clients without fractional support
                // can still render sharply.
                if (value.factor <= 0) return;
                const factor: u32 = @intCast(value.factor);
                if (factor == self.display_scale) return;
                self.display_scale = factor;
                self.scale_dirty = true;
            },
            else => {},
        }
    }

    fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Connection) void {
        switch (event) {
            .capabilities => |caps| {
                if (caps.capabilities.pointer and self.pointer == null) {
                    const pointer = seat.getPointer() catch return;
                    self.pointer = pointer;
                    pointer.setListener(*Connection, pointerListener, self);
                    if (self.cursor_shape_manager) |manager| {
                        self.cursor_shape_device = manager.getPointer(pointer) catch null;
                    }
                }
                if (caps.capabilities.keyboard and self.keyboard == null) {
                    const keyboard = seat.getKeyboard() catch return;
                    self.keyboard = keyboard;
                    keyboard.setListener(*Connection, keyboardListener, self);
                }
            },
            .name => {},
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *Connection) void {
        const inp = self.input orelse return;
        switch (event) {
            .enter => |e| {
                if (self.clipboard) |clip| clip.updateSerial(e.serial);
                self.pointer_enter_serial = e.serial;
                self.last_serial = e.serial;
                self.applyCursor();
                inp.pointerEnter(e.surface, e.surface_x.toDouble(), e.surface_y.toDouble());
            },
            .leave => {
                self.pointer_enter_serial = null;
                inp.pointerLeave();
            },
            .motion => |m| {
                inp.pointerMotion(m.surface_x.toDouble(), m.surface_y.toDouble(), m.time);
            },
            .button => |b| {
                if (self.clipboard) |clip| clip.updateSerial(b.serial);
                self.last_serial = b.serial;
                inp.pointerButton(b.button, b.state == .pressed, b.time);
            },
            .axis => |a| {
                inp.pointerAxis(a.axis == .vertical_scroll, a.value.toDouble(), a.time);
            },
            else => {},
        }
    }

    fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Connection) void {
        const inp = self.input orelse return;
        switch (event) {
            .keymap => |km| {
                if (km.format != .xkb_v1) return;
                defer _ = std.os.linux.close(km.fd);
                const mapped = std.posix.mmap(
                    null,
                    km.size,
                    .{ .READ = true },
                    .{ .TYPE = .PRIVATE },
                    km.fd,
                    0,
                ) catch return;
                defer std.posix.munmap(mapped);
                inp.setKeymapFromBuffer(mapped);
            },
            .enter => |e| {
                // `set_selection` is only accepted with a serial from a recent
                // seat event, and gaining focus is one.
                if (self.clipboard) |clip| clip.updateSerial(e.serial);
                self.last_serial = e.serial;
                inp.keyboardEnter(e.surface);
            },
            .leave => {
                inp.keyboardLeave();
            },
            .key => |k| {
                if (self.clipboard) |clip| clip.updateSerial(k.serial);
                self.last_serial = k.serial;
                inp.handleKey(k.key + 8, k.state == .pressed, k.time);
            },
            .modifiers => |m| {
                inp.updateModifiers(m.mods_depressed, m.mods_latched, m.mods_locked, m.group);
            },
            else => {},
        }
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    // Version 3 adds `wl_surface.set_buffer_scale`, which is
                    // how the embedder implements HiDPI.
                    const version = @min(global.version, wl.Compositor.generated_version);
                    globals.compositor = registry.bind(global.name, wl.Compositor, version) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    // Bind as high as the compositor advertises (capped by the
                    // generated protocol) so xdg_toplevel.configure_bounds (v4)
                    // and wm_capabilities (v5) are delivered.
                    const version = @min(global.version, xdg.WmBase.generated_version);
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, version) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                    globals.data_device_manager = registry.bind(global.name, wl.DataDeviceManager, @min(global.version, 3)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    globals.seat_name = global.name;
                } else if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    globals.outputs.append(globals.allocator, .{
                        .name = global.name,
                        .version = global.version,
                    }) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wp.CursorShapeManagerV1.interface.name) == .eq) {
                    if (globals.cursor_shape_manager_name == null) {
                        globals.cursor_shape_manager_name = global.name;
                        globals.cursor_shape_manager_version = global.version;
                    }
                } else if (std.mem.orderZ(u8, global.interface, zwlr.LayerShellV1.interface.name) == .eq) {
                    if (globals.layer_shell_name == null) {
                        globals.layer_shell_name = global.name;
                        globals.layer_shell_version = global.version;
                    }
                } else if (std.mem.orderZ(u8, global.interface, xdg.ActivationV1.interface.name) == .eq) {
                    if (globals.activation_name == null) {
                        globals.activation_name = global.name;
                        globals.activation_version = global.version;
                    }
                }
            },
            .global_remove => {},
        }
    }
};

/// The cursor-shape-v1 shape for a framework cursor shape. The enums have the
/// same names; this switch keeps the dependency explicit and compiler-checked.
fn protocolShape(shape: mouse_cursor.Cursor.Shape) wp.CursorShapeDeviceV1.Shape {
    return switch (shape) {
        .default => .default,
        .context_menu => .context_menu,
        .help => .help,
        .pointer => .pointer,
        .progress => .progress,
        .wait => .wait,
        .cell => .cell,
        .crosshair => .crosshair,
        .text => .text,
        .vertical_text => .vertical_text,
        .alias => .alias,
        .copy => .copy,
        .move => .move,
        .no_drop => .no_drop,
        .not_allowed => .not_allowed,
        .grab => .grab,
        .grabbing => .grabbing,
        .e_resize => .e_resize,
        .n_resize => .n_resize,
        .ne_resize => .ne_resize,
        .nw_resize => .nw_resize,
        .s_resize => .s_resize,
        .se_resize => .se_resize,
        .sw_resize => .sw_resize,
        .w_resize => .w_resize,
        .ew_resize => .ew_resize,
        .ns_resize => .ns_resize,
        .nesw_resize => .nesw_resize,
        .nwse_resize => .nwse_resize,
        .col_resize => .col_resize,
        .row_resize => .row_resize,
        .all_scroll => .all_scroll,
        .zoom_in => .zoom_in,
        .zoom_out => .zoom_out,
    };
}

/// How long one refresh lasts, from a `wl_output` mode's refresh rate in mHz.
fn framePeriodNs(refresh_mhz: u32) u64 {
    return std.time.ns_per_s * @as(u64, std.time.ms_per_s) / refresh_mhz;
}

test "the refresh period follows the output mode" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 6_060_238), framePeriodNs(165_010));
}
