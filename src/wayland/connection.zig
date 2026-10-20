const std = @import("std");

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const engine = @import("../engine.zig");
const input = @import("../input.zig");
const clipboard = @import("clipboard.zig");
const window = @import("window.zig");
const Context = @import("../context.zig").Context;

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    seat_name: ?u32 = null,
    /// The first output, by registry name and version.
    output_name: ?u32 = null,
    output_version: u32 = 0,
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
    output: ?*wl.Output = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    /// The engine-facing input and clipboard handlers, wired by `bindSeat`.
    input: ?*input.Input = null,
    clipboard: ?*clipboard.Clipboard = null,
    /// The output's current mode, for `FlutterEngineNotifyDisplayUpdate` and
    /// the frame clock.
    display_width: u32 = 0,
    display_height: u32 = 0,
    refresh_mhz: u32 = 0,
    frame_period_ns: u64 = engine.default_frame_period_ns,

    pub fn connect(allocator: std.mem.Allocator) !*Connection {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        errdefer registry.destroy();

        var globals = Globals{};
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoCompositor;
        const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
        const data_device_manager = globals.data_device_manager orelse return error.NoDataDeviceManager;
        const seat_name = globals.seat_name orelse return error.NoSeat;

        const self = try allocator.create(Connection);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .wm_base = wm_base,
            .data_device_manager = data_device_manager,
            .seat_name = seat_name,
        };

        // Bind the output now: its mode events are what the display refreshes
        // at, and arrive on the roundtrips after this.
        if (globals.output_name) |name| {
            const version = @min(globals.output_version, wl.Output.generated_version);
            self.output = registry.bind(name, wl.Output, version) catch null;
            if (self.output) |output| output.setListener(*Connection, outputListener, self);
        }

        return self;
    }

    pub fn deinit(self: *Connection) void {
        if (self.clipboard) |clip| clip.deinit();
        if (self.keyboard) |k| k.destroy();
        if (self.pointer) |p| p.destroy();
        if (self.output) |o| {
            // `release` needs version 3; below that the proxy is all there is.
            if (o.getVersion() >= 3) o.release() else @as(*wl.Proxy, @ptrCast(o)).destroy();
        }
        if (self.seat) |s| s.destroy();
        self.compositor.destroy();
        self.wm_base.destroy();
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
        if (self.display.dispatch() != .SUCCESS) return error.DispatchFailed;
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
        toplevel.setTitle("fembed");

        return window.Window.create(self.allocator, surface, xdg_surface, toplevel);
    }

    /// Block until the compositor has sent the initial configure and the
    /// output's mode has been reported, so the surface is ready for buffers and
    /// the engine can be told the display it draws on.
    pub fn waitReady(self: *Connection, win: *window.Window) !void {
        while (!win.configured) try self.roundtrip();
        // The output's mode arrives in response to the bind, which happened
        // before this; one more roundtrip makes sure it has been dispatched.
        if (self.refresh_mhz == 0) try self.roundtrip();
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
                inp.pointerEnter(e.surface_x.toDouble(), e.surface_y.toDouble());
            },
            .leave => {
                inp.pointerLeave();
            },
            .motion => |m| {
                inp.pointerMotion(m.surface_x.toDouble(), m.surface_y.toDouble(), m.time);
            },
            .button => |b| {
                if (self.clipboard) |clip| clip.updateSerial(b.serial);
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
            },
            .key => |k| {
                if (self.clipboard) |clip| clip.updateSerial(k.serial);
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
                    globals.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                    globals.data_device_manager = registry.bind(global.name, wl.DataDeviceManager, @min(global.version, 3)) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    globals.seat_name = global.name;
                } else if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    if (globals.output_name == null) {
                        globals.output_name = global.name;
                        globals.output_version = global.version;
                    }
                }
            },
            .global_remove => {},
        }
    }
};

/// How long one refresh lasts, from a `wl_output` mode's refresh rate in mHz.
fn framePeriodNs(refresh_mhz: u32) u64 {
    return std.time.ns_per_s * @as(u64, std.time.ms_per_s) / refresh_mhz;
}

test "the refresh period follows the output mode" {
    const testing = std.testing;
    try testing.expectEqual(@as(u64, 6_060_238), framePeriodNs(165_010));
}
