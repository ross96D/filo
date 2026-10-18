const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const input = @import("input.zig");
const engine = @import("engine.zig");

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    seat_name: ?u32 = null,
};

pub const Window = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,
    seat_name: u32,
    seat: ?*wl.Seat = null,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    input: ?*input.Input = null,
    running: bool = true,
    configured: bool = false,

    pub fn create(allocator: std.mem.Allocator) !*Window {
        const display = try wl.Display.connect(null);
        errdefer display.disconnect();
        const registry = try display.getRegistry();
        errdefer registry.destroy();

        var globals = Globals{};
        registry.setListener(*Globals, registryListener, &globals);
        if (display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        const compositor = globals.compositor orelse return error.NoCompositor;
        const wm_base = globals.wm_base orelse return error.NoXdgWmBase;
        const seat_name = globals.seat_name orelse return error.NoSeat;

        const surface = try compositor.createSurface();
        errdefer surface.destroy();
        const xdg_surface = try wm_base.getXdgSurface(surface);
        errdefer xdg_surface.destroy();
        const toplevel = try xdg_surface.getToplevel();
        errdefer toplevel.destroy();
        toplevel.setTitle("fembed");

        const self = try allocator.create(Window);
        self.* = .{
            .allocator = allocator,
            .display = display,
            .registry = registry,
            .compositor = compositor,
            .wm_base = wm_base,
            .seat_name = seat_name,
            .surface = surface,
            .xdg_surface = xdg_surface,
            .toplevel = toplevel,
        };

        xdg_surface.setListener(*Window, xdgSurfaceListener, self);
        toplevel.setListener(*Window, toplevelListener, self);

        surface.commit();

        return self;
    }

    /// Attach an input handler and bind pointer/keyboard from the seat.
    pub fn setupInput(self: *Window, inp: *input.Input) !void {
        self.input = inp;
        self.seat = try self.registry.bind(self.seat_name, wl.Seat, 8);
        self.seat.?.setListener(*Window, seatListener, self);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
    }

    /// Block until the compositor has sent the initial configure, so that the
    /// surface is ready to accept buffers (from the Vulkan swapchain).
    pub fn waitConfigured(self: *Window) !void {
        while (!self.configured) {
            if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }
    }

    /// Blocking dispatch loop until the window is closed. Also pumps the
    /// engine's platform task runner via an eventfd so that framework-to-host
    /// platform messages (e.g. keyboard state sync) get a timely response.
    pub fn run(self: *Window, eng: *engine.Engine) !void {
        const display_fd = self.display.getFd();
        const task_fd = eng.getPlatformEventFd();
        const pollin: i16 = std.posix.POLL.IN;
        var poll_fds = [_]std.posix.pollfd{
            .{ .fd = display_fd, .events = pollin, .revents = 0 },
            .{ .fd = task_fd, .events = pollin, .revents = 0 },
        };

        while (self.running) {
            while (!self.display.prepareRead()) {
                if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
            }
            if (self.display.flush() != .SUCCESS) return error.DispatchFailed;

            const n = try std.posix.poll(&poll_fds, -1);
            if (n > 0) {
                if (poll_fds[0].revents & pollin != 0) {
                    if (self.display.readEvents() != .SUCCESS) return error.DispatchFailed;
                } else {
                    self.display.cancelRead();
                }
                if (poll_fds[1].revents & pollin != 0) {
                    eng.drainPlatformTasks();
                }
            }

            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
        }
    }

    pub fn destroy(self: *Window) void {
        if (self.keyboard) |k| k.destroy();
        if (self.pointer) |p| p.destroy();
        if (self.seat) |s| s.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        self.compositor.destroy();
        self.wm_base.destroy();
        self.registry.destroy();
        self.display.disconnect();
        self.allocator.destroy(self);
    }

    fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, globals: *Globals) void {
        switch (event) {
            .global => |global| {
                if (std.mem.orderZ(u8, global.interface, wl.Compositor.interface.name) == .eq) {
                    globals.compositor = registry.bind(global.name, wl.Compositor, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, xdg.WmBase.interface.name) == .eq) {
                    globals.wm_base = registry.bind(global.name, xdg.WmBase, 1) catch return;
                } else if (std.mem.orderZ(u8, global.interface, wl.Seat.interface.name) == .eq) {
                    globals.seat_name = global.name;
                }
            },
            .global_remove => {},
        }
    }

    fn seatListener(seat: *wl.Seat, event: wl.Seat.Event, self: *Window) void {
        switch (event) {
            .capabilities => |caps| {
                if (caps.capabilities.pointer and self.pointer == null) {
                    const pointer = seat.getPointer() catch return;
                    self.pointer = pointer;
                    pointer.setListener(*Window, pointerListener, self);
                }
                if (caps.capabilities.keyboard and self.keyboard == null) {
                    const keyboard = seat.getKeyboard() catch return;
                    self.keyboard = keyboard;
                    keyboard.setListener(*Window, keyboardListener, self);
                }
            },
            .name => {},
        }
    }

    fn pointerListener(_: *wl.Pointer, event: wl.Pointer.Event, self: *Window) void {
        const inp = self.input orelse return;
        switch (event) {
            .enter => |e| {
                inp.pointerEnter(e.surface_x.toDouble(), e.surface_y.toDouble());
            },
            .leave => {
                inp.pointerLeave();
            },
            .motion => |m| {
                inp.pointerMotion(m.surface_x.toDouble(), m.surface_y.toDouble(), m.time);
            },
            .button => |b| {
                inp.pointerButton(b.button, b.state == .pressed, b.time);
            },
            .axis => |a| {
                inp.pointerAxis(a.axis == .vertical_scroll, a.value.toDouble(), a.time);
            },
            else => {},
        }
    }

    fn keyboardListener(_: *wl.Keyboard, event: wl.Keyboard.Event, self: *Window) void {
        const inp = self.input orelse return;
        switch (event) {
            .keymap => |km| {
                if (km.format != .xkb_v1) return;
                defer _ = std.os.linux.close(km.fd);
                const mapped = posix.mmap(
                    null,
                    km.size,
                    .{ .READ = true },
                    .{ .TYPE = .PRIVATE },
                    km.fd,
                    0,
                ) catch return;
                defer posix.munmap(mapped);
                inp.setKeymapFromBuffer(mapped);
            },
            .key => |k| {
                inp.handleKey(k.key, k.state == .pressed, k.time);
            },
            .modifiers => |m| {
                inp.updateModifiers(m.mods_depressed, m.mods_latched, m.mods_locked, m.group);
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
            .configure => {},
            .close => self.running = false,
            else => {},
        }
    }
};
