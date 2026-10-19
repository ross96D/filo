const std = @import("std");
const posix = std.posix;

const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const input = @import("input.zig");
const engine = @import("engine.zig");
const clipboard = @import("clipboard.zig");

const Globals = struct {
    compositor: ?*wl.Compositor = null,
    wm_base: ?*xdg.WmBase = null,
    data_device_manager: ?*wl.DataDeviceManager = null,
    seat_name: ?u32 = null,
};

/// What a configure of 0×0 means: the compositor is leaving the size to us.
const default_width = 800;
const default_height = 600;

/// The scale factor reported to the engine. Wayland lets the compositor scale
/// the buffer we attach instead, which is what we rely on: the swapchain is
/// always as big as the engine drew. Fractional and integer buffer scale would
/// both mean drawing at a different size than we tell the engine.
const default_pixel_ratio = 1;

pub const Window = struct {
    allocator: std.mem.Allocator,
    display: *wl.Display,
    registry: *wl.Registry,
    compositor: *wl.Compositor,
    wm_base: *xdg.WmBase,
    data_device_manager: *wl.DataDeviceManager,
    seat_name: u32,
    seat: ?*wl.Seat = null,
    surface: *wl.Surface,
    xdg_surface: *xdg.Surface,
    toplevel: *xdg.Toplevel,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    clipboard: ?*clipboard.Clipboard = null,
    input: ?*input.Input = null,
    running: bool = true,
    configured: bool = false,
    /// Size the compositor last asked for, in surface (logical) pixels. Starts
    /// at the default because the initial configure may leave the size to us.
    width: u32 = default_width,
    height: u32 = default_height,
    pixel_ratio: f64 = default_pixel_ratio,
    /// Set by a configure that changed the size, drained by `run`, which
    /// forwards it to the engine.
    resized: bool = false,

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
        const data_device_manager = globals.data_device_manager orelse return error.NoDataDeviceManager;
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
            .data_device_manager = data_device_manager,
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

    /// Attach an input handler and bind pointer/keyboard (and the clipboard)
    /// from the seat.
    pub fn setupInput(self: *Window, inp: *input.Input) !void {
        self.input = inp;
        self.seat = try self.registry.bind(self.seat_name, wl.Seat, 8);
        self.seat.?.setListener(*Window, seatListener, self);
        if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;

        self.clipboard = try clipboard.Clipboard.init(
            self.allocator,
            self.display,
            self.data_device_manager,
            self.seat.?,
        );
    }

    /// Block until the compositor has sent the initial configure, so that the
    /// surface is ready to accept buffers (from the Vulkan swapchain).
    pub fn waitConfigured(self: *Window) !void {
        while (!self.configured) {
            if (self.display.roundtrip() != .SUCCESS) return error.RoundtripFailed;
        }
        // The caller creates the swapchain and sends the initial window metrics
        // from `width`/`height` right after this, so a configure that arrived
        // while we waited is already accounted for.
        self.resized = false;
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
            .{ .fd = -1, .events = pollin, .revents = 0 },
        };

        while (self.running) {
            while (!self.display.prepareRead()) {
                if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;
            }
            if (self.display.flush() != .SUCCESS) return error.DispatchFailed;

            // A clipboard paste adds its pipe to the poll set, so it can be
            // drained (and answered) without ever blocking the loop.
            var count: usize = 2;
            if (self.clipboard) |clip| {
                if (clip.pollFd()) |fd| {
                    poll_fds[2] = .{ .fd = fd, .events = pollin, .revents = 0 };
                    count = 3;
                }
            }

            const n = try std.posix.poll(poll_fds[0..count], -1);
            if (n > 0) {
                if (poll_fds[0].revents & pollin != 0) {
                    if (self.display.readEvents() != .SUCCESS) return error.DispatchFailed;
                } else {
                    self.display.cancelRead();
                }
                if (poll_fds[1].revents & pollin != 0) {
                    eng.drainPlatformTasks();
                }
                if (count == 3 and poll_fds[2].revents != 0) {
                    // Any event retires the transfer: readable, end-of-file
                    // (the source closed without writing, i.e. empty text), or
                    // an error. `POLLIN` alone would miss the empty case.
                    if (self.clipboard) |clip| clip.pump();
                }
            }

            if (self.display.dispatchPending() != .SUCCESS) return error.DispatchFailed;

            self.applyResize(eng);
        }
    }

    /// Forward a size the compositor asked for to the engine. The swapchain
    /// itself is not touched here: it follows the size the engine says it draws
    /// at (see `vulkan.Surface.acquire`), which is what the metrics below tell
    /// it, so there is nothing to hand over between threads.
    fn applyResize(self: *Window, eng: *engine.Engine) void {
        if (!self.resized) return;
        self.resized = false;

        std.debug.print("fembed: window resized to {}x{}\n", .{ self.width, self.height });
        eng.sendWindowMetrics(self.width, self.height, self.pixel_ratio);
        // A window metrics event makes the framework relayout and schedule a
        // frame on its own; asking for one anyway means a resize can never be
        // left unpainted.
        eng.scheduleFrame();
    }

    pub fn destroy(self: *Window) void {
        if (self.clipboard) |clip| clip.deinit();
        if (self.keyboard) |k| k.destroy();
        if (self.pointer) |p| p.destroy();
        if (self.seat) |s| s.destroy();
        self.toplevel.destroy();
        self.xdg_surface.destroy();
        self.surface.destroy();
        self.compositor.destroy();
        self.wm_base.destroy();
        // `wl_data_device_manager` has no destructor below version 4, which is
        // all we bind, so drop the proxy directly.
        @as(*wl.Proxy, @ptrCast(self.data_device_manager)).destroy();
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
                } else if (std.mem.orderZ(u8, global.interface, wl.DataDeviceManager.interface.name) == .eq) {
                    globals.data_device_manager = registry.bind(global.name, wl.DataDeviceManager, @min(global.version, 3)) catch return;
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
            .close => self.running = false,
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
