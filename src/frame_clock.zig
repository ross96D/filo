const std = @import("std");

const zio = @import("zio");
const ev = zio.ev;

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Context = @import("context.zig").Context;

/// The frame clock for one surface: it answers the engine's vsync requests from
/// the compositor's `wl_surface.frame` callbacks, and hands the engine a tick
/// from its own clock when the compositor does not repaint within two refresh
/// periods (niri, for one, does not paint a surface nobody can see).
pub const FrameClock = struct {
    ctx: *Context,
    surface: *wl.Surface,
    period_ns: u64,

    /// The frame callback we are waiting on, or null when none is armed.
    callback: ?*wl.Callback = null,
    /// When the callback above was armed, to notice a repaint that never comes.
    armed_at_ns: u64 = 0,
    /// A compositor tick that arrived with no frame waiting for it.
    tick: ?VsyncTimes = null,
    /// Whether the first tick has been answered from our own clock, which is all
    /// it takes to get the first frame on screen.
    bootstrapped: bool = false,

    timer: ev.Timer = .init(.none),
    timer_armed: bool = false,

    pub fn init(ctx: *Context, surface: *wl.Surface, period_ns: u64) !*FrameClock {
        const self = try ctx.allocator.create(FrameClock);
        self.* = .{
            .ctx = ctx,
            .surface = surface,
            .period_ns = period_ns,
        };
        self.timer.c.userdata = self;
        self.timer.c.callback = onTimeout;
        return self;
    }

    pub fn deinit(self: *FrameClock) void {
        self.ctx.allocator.destroy(self);
    }

    pub fn setPeriod(self: *FrameClock, period_ns: u64) void {
        self.period_ns = period_ns;
    }

    /// Answer the engine when it is waiting for the display's next refresh.
    pub fn service(self: *FrameClock) void {
        if (!self.ctx.eng.hasVsyncRequests()) return;

        // A tick the compositor has already given us is the display's own frame
        // clock, and the best answer there is.
        if (self.tick != null) {
            self.fireTick();
            return;
        }

        if (self.callback == null and !self.arm()) {
            // No frame clock at all: keep the engine going at the nominal rate
            // rather than stalling it every frame.
            const now = self.ctx.eng.currentTime();
            self.ctx.eng.fireVsync(now, now + self.period_ns);
            return;
        }

        // The first frame has not been presented yet, so the compositor has
        // nothing to time and need not answer a frame request at all (niri does
        // not). Answer once from our own clock so the engine draws that first
        // frame; every tick after it comes from the compositor.
        if (!self.bootstrapped) {
            self.bootstrapped = true;
            const now = self.ctx.eng.currentTime();
            self.ctx.eng.fireVsync(now, now + self.period_ns);
            return;
        }

        // A compositor is only obliged to answer a frame request when it paints
        // the surface, and niri does not paint for the request alone: if the
        // repaint that would have answered this one has already been and gone,
        // no tick is coming. Keep the request armed for the next repaint, but
        // hand the engine a tick from our own clock rather than stalling it.
        if (self.ctx.eng.currentTime() -% self.armed_at_ns > 2 * self.period_ns) {
            const now = self.ctx.eng.currentTime();
            self.ctx.eng.fireVsync(now, now + self.period_ns);
            return;
        }

        // The compositor still owes us a tick. It may never come, so make sure
        // the timer that would answer the request is running.
        self.armTimer();
    }

    /// Ask the compositor for the next repaint of the surface. One is kept
    /// armed whenever the engine might draw again, so that the request is always
    /// on the wire before the frame it should report. False means the request
    /// could not be made, and there is no frame clock to wait on.
    fn arm(self: *FrameClock) bool {
        if (self.callback != null) return true;

        const callback = self.surface.frame() catch |err| {
            std.debug.print("fembed: wl_surface.frame failed: {}\n", .{err});
            return false;
        };
        callback.setListener(*FrameClock, onFrame, self);
        self.callback = callback;
        self.armed_at_ns = self.ctx.eng.currentTime();
        return true;
    }

    /// Start the timer that answers a frame request the compositor did not.
    fn armTimer(self: *FrameClock) void {
        if (self.timer_armed) return;
        self.ctx.loop.setTimer(&self.timer, .{
            .duration = .fromNanoseconds(2 * self.period_ns),
        });
        self.timer_armed = true;
    }

    fn clearTimer(self: *FrameClock) void {
        if (!self.timer_armed) return;
        self.timer_armed = false;
        _ = self.ctx.loop.clearTimer(&self.timer);
    }

    /// Answer the engine from the cached frame time, clearing the cache so it
    /// can never be fired twice or out of order.
    fn fireTick(self: *FrameClock) void {
        const tick = self.tick.?;
        self.tick = null;
        self.ctx.eng.fireVsync(tick.start_ns, tick.target_ns);
    }

    /// The compositor saying the surface has been repainted: the display's frame
    /// clock tick.
    fn onFrame(callback: *wl.Callback, event: wl.Callback.Event, self: *FrameClock) void {
        switch (event) {
            .done => {
                // The compositor destroys the object after firing it; the proxy
                // on this side is ours to free, and has no destructor request.
                callback.destroy();
                self.callback = null;
                self.clearTimer();

                // Cache the freshest frame time; a request that arrives before
                // the next repaint is answered from it. Overwriting every time
                // keeps a stale tick from being fired after a newer frame's
                // timestamp.
                self.tick = vsyncTimes(self.ctx.eng.currentTime(), self.period_ns);
                if (self.ctx.eng.hasVsyncRequests()) self.fireTick();
                _ = self.arm();
            },
        }
    }

    /// No frame tick arrived within two refresh periods. The frame request
    /// stays armed for the next repaint, but the engine gets a tick from our
    /// own clock so it does not stall.
    fn onTimeout(_: *ev.Loop, c: *ev.Completion) void {
        const self: *FrameClock = @ptrCast(@alignCast(c.userdata.?));
        self.timer_armed = false;

        if (!self.ctx.eng.hasVsyncRequests()) return;
        // A tick that arrived while the timer was firing already answered
        // whatever was waiting; let the normal path deal with it.
        if (self.tick != null or self.callback == null) return self.service();

        const now = self.ctx.eng.currentTime();
        self.ctx.eng.fireVsync(now, now + self.period_ns);
    }
};

const VsyncTimes = struct { start_ns: u64, target_ns: u64 };

/// The frame timestamps to hand back to the engine, in the engine's own clock:
/// the start is "now" and the target one refresh later. The compositor's frame
/// callback time is deliberately not used for the start, even though it lines
/// up with the same monotonic clock in practice: it is truncated to whole
/// milliseconds, and mixing it with the engine's nanosecond clock makes the
/// reported start step backwards by the sub-millisecond remainder, which the
/// engine rejects.
fn vsyncTimes(now_ns: u64, period_ns: u64) VsyncTimes {
    return .{ .start_ns = now_ns, .target_ns = now_ns + period_ns };
}

test "the vsync timestamps are the engine's clock, target one refresh ahead" {
    const testing = std.testing;

    // 165 Hz: 6.06 ms per refresh.
    const period = 6_060_238;
    const now: u64 = 10 * std.time.ns_per_ms;
    const times = vsyncTimes(now, period);
    try testing.expectEqual(now, times.start_ns);
    try testing.expectEqual(now + period, times.target_ns);
}
