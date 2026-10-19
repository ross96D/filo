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
    /// The first output, by registry name and version. Bound after the window
    /// exists, so that the events a bind sends are not dispatched before there
    /// is anything to listen for them.
    output_name: ?u32 = null,
    output_version: u32 = 0,
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
    output: ?*wl.Output = null,
    pointer: ?*wl.Pointer = null,
    keyboard: ?*wl.Keyboard = null,
    clipboard: ?*clipboard.Clipboard = null,
    input: ?*input.Input = null,
    /// The engine, once the event loop runs: the vsync handler answers it.
    eng: ?*engine.Engine = null,
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
    /// The output's current mode, for `FlutterEngineNotifyDisplayUpdate`.
    display_width: u32 = 0,
    display_height: u32 = 0,
    refresh_mhz: u32 = 0,
    /// How far apart the display's refreshes are, for the vsync timestamps.
    frame_period_ns: u64 = engine.default_frame_period_ns,
    /// The frame callback we are waiting on, or null when none is armed.
    frame_callback: ?*wl.Callback = null,
    /// When the callback above was armed, to notice a repaint that never comes.
    armed_at_ns: u64 = 0,
    /// A compositor tick that arrived with no frame waiting for it.
    tick: ?VsyncTimes = null,
    /// Whether the first tick has been answered from our own clock, which is all
    /// it takes to get the first frame on screen.
    bootstrapped: bool = false,

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

        if (globals.output_name) |name| {
            const version = @min(globals.output_version, wl.Output.generated_version);
            self.output = registry.bind(name, wl.Output, version) catch null;
            if (self.output) |output| output.setListener(*Window, outputListener, self);
        }

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
        // The output's mode arrives in response to the bind, which happened
        // before this; one more roundtrip makes sure it has been dispatched
        // before the display is reported to the engine.
        if (self.refresh_mhz == 0) {
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
        self.eng = eng;
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

            // While the engine is waiting for a tick, wake up often enough to
            // notice a repaint that is not coming; otherwise wait for events.
            const timeout_ms: i32 = if (eng.hasVsyncRequests())
                @intCast(2 * self.frame_period_ns / std.time.ns_per_ms)
            else
                -1;
            const n = try std.posix.poll(poll_fds[0..count], timeout_ms);
            // A prepared read has to be either read or cancelled, and a timeout
            // (or an error on the display fd) means there is nothing to read.
            if (n > 0 and poll_fds[0].revents & pollin != 0) {
                if (self.display.readEvents() != .SUCCESS) return error.DispatchFailed;
            } else {
                self.display.cancelRead();
            }
            if (n > 0) {
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
            self.serviceVsync(eng);
        }
    }

    /// Answer the engine when it is waiting for the display's next refresh. The
    /// compositor's frame callback is that refresh: one is always armed, before
    /// the frame that will be presented, so it is answered by the repaint that
    /// shows that frame.
    fn serviceVsync(self: *Window, eng: *engine.Engine) void {
        if (!eng.hasVsyncRequests()) return;

        // A tick the compositor has already given us is the display's own frame
        // clock, and the best answer there is.
        if (self.tick) |tick| {
            self.tick = null;
            eng.fireVsync(tick.start_ns, tick.target_ns);
            return;
        }

        if (self.frame_callback == null and !self.armFrameCallback(eng)) {
            // No frame clock at all: keep the engine going at the nominal rate
            // rather than stalling it every frame.
            const now = eng.currentTime();
            eng.fireVsync(now, now + self.frame_period_ns);
            return;
        }

        // The first frame has not been presented yet, so the compositor has
        // nothing to time and need not answer a frame request at all (niri does
        // not). Answer once from our own clock so the engine draws that first
        // frame; every tick after it comes from the compositor.
        if (!self.bootstrapped) {
            self.bootstrapped = true;
            const now = eng.currentTime();
            eng.fireVsync(now, now + self.frame_period_ns);
            return;
        }

        // A compositor is only obliged to answer a frame request when it paints
        // the surface, and niri does not paint for the request alone: if the
        // repaint that would have answered this one has already been and gone,
        // no tick is coming. Keep the request armed for the next repaint, but
        // hand the engine a tick from our own clock rather than stalling it.
        if (eng.currentTime() - self.armed_at_ns > 2 * self.frame_period_ns) {
            const now = eng.currentTime();
            eng.fireVsync(now, now + self.frame_period_ns);
        }
    }

    /// Ask the compositor for the next repaint of the surface. One is kept
    /// armed whenever the engine might draw again, so that the request is always
    /// on the wire before the frame it should report. False means the request
    /// could not be made, and there is no frame clock to wait on.
    fn armFrameCallback(self: *Window, eng: *engine.Engine) bool {
        if (self.frame_callback != null) return true;

        const callback = self.surface.frame() catch |err| {
            std.debug.print("fembed: wl_surface.frame failed: {}\n", .{err});
            return false;
        };
        callback.setListener(*Window, frameListener, self);
        self.frame_callback = callback;
        self.armed_at_ns = eng.currentTime();
        // The request has to be on the wire before the frame the engine is about
        // to draw is committed.
        _ = self.display.flush();
        return true;
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

    /// The output's current mode is what the display actually refreshes at, and
    /// what the engine wants to know about.
    fn outputListener(_: *wl.Output, event: wl.Output.Event, self: *Window) void {
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
                if (self.eng) |eng| eng.frame_period_ns = self.frame_period_ns;
            },
            else => {},
        }
    }

    /// The compositor saying the surface has been repainted: the display's frame
    /// clock tick.
    fn frameListener(callback: *wl.Callback, event: wl.Callback.Event, self: *Window) void {
        switch (event) {
            .done => |done| {
                // The compositor destroys the object after firing it; the proxy
                // on this side is ours to free, and has no destructor request.
                callback.destroy();
                self.frame_callback = null;

                const eng = self.eng orelse return;
                const times = vsyncTimes(eng.currentTime(), done.callback_data, self.frame_period_ns);
                if (eng.hasVsyncRequests()) {
                    eng.fireVsync(times.start_ns, times.target_ns);
                } else {
                    // Nothing is waiting for it, but the next request should not
                    // have to wait for another repaint.
                    self.tick = times;
                }
                _ = self.armFrameCallback(eng);
            },
        }
    }

    pub fn destroy(self: *Window) void {
        if (self.clipboard) |clip| clip.deinit();
        if (self.keyboard) |k| k.destroy();
        if (self.pointer) |p| p.destroy();
        if (self.output) |o| {
            // `release` needs version 3; below that the proxy is all there is.
            if (o.getVersion() >= 3) o.release() else @as(*wl.Proxy, @ptrCast(o)).destroy();
        }
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
                } else if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name) == .eq) {
                    // Bound once the window exists: the events a bind sends are
                    // dispatched on the roundtrips after it, and there has to be
                    // a listener by then.
                    if (globals.output_name == null) {
                        globals.output_name = global.name;
                        globals.output_version = global.version;
                    }
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

/// How long one refresh lasts, from a `wl_output` mode's refresh rate in mHz.
fn framePeriodNs(refresh_mhz: u32) u64 {
    return std.time.ns_per_s * @as(u64, std.time.ms_per_s) / refresh_mhz;
}

const VsyncTimes = struct { start_ns: u64, target_ns: u64 };

/// The frame timestamps to hand back to the engine. `callback_ms` is the frame
/// callback's time, which the protocol leaves with a base the spec does not
/// define (in practice the monotonic clock on wlroots-like compositors) and
/// truncates to milliseconds, so it is only usable when it lines up with the
/// engine's own clock. A start time the engine believes is in the future would
/// park the frame until then, and a wrapped one is just as wrong, so anything
/// that does not line up becomes "now".
fn vsyncTimes(now_ns: u64, callback_ms: u32, period_ns: u64) VsyncTimes {
    const callback_ns = @as(u64, callback_ms) * std.time.ns_per_ms;
    // A millisecond of truncation plus scheduling jitter; a different timebase
    // is off by far more than this.
    const tolerance_ns = 50 * std.time.ns_per_ms;
    const start_ns = if (callback_ns <= now_ns and now_ns - callback_ns <= tolerance_ns)
        callback_ns
    else
        now_ns;
    return .{ .start_ns = start_ns, .target_ns = start_ns +| period_ns };
}

test "the vsync timestamps follow the compositor's frame time when it is usable" {
    const testing = std.testing;

    // 165 Hz: 6.06 ms per refresh, and the callback time is the frame that just
    // happened, a millisecond or so in the past.
    const period = framePeriodNs(165_010);
    try testing.expectEqual(@as(u64, 6_060_238), period);

    const now: u64 = 10 * std.time.ns_per_ms;
    const times = vsyncTimes(now, 9, period);
    try testing.expectEqual(@as(u64, 9 * std.time.ns_per_ms), times.start_ns);
    try testing.expectEqual(times.start_ns + period, times.target_ns);

    // A callback time in the future is a different clock (or a wrap): the engine
    // must not be told to wait for it.
    try testing.expectEqual(now, vsyncTimes(now, 11, period).start_ns);
    // So is one from long ago: further back than the tolerance, e.g. an epoch
    // that is not the monotonic clock at all.
    try testing.expectEqual(60 * std.time.ns_per_ms, vsyncTimes(60 * std.time.ns_per_ms, 0, period).start_ns);
    // And a 32-bit millisecond wrap lands in the future, not in the past.
    try testing.expectEqual(now, vsyncTimes(now, std.math.maxInt(u32), period).start_ns);
}

test "a configure that leaves the size to us is not a resize" {
    const testing = std.testing;

    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(0, 0));
    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(0, 600));
    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(800, 0));
    try testing.expectEqual(@as(?[2]u32, null), Window.configuredSize(-1, 1080));
    try testing.expectEqual(@as(?[2]u32, .{ 1024, 768 }), Window.configuredSize(1024, 768));
}
