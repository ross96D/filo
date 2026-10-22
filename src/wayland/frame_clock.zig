const std = @import("std");

const zio = @import("zio");
const ev = zio.ev;

const wayland = @import("wayland");
const wl = wayland.client.wl;

const Context = @import("../context.zig").Context;

/// The one frame clock for the whole engine. It answers the engine's vsync
/// requests from `wl_surface.frame` callbacks on *every* surface, and hands the
/// engine a tick from its own clock when no surface has been repainted within
/// two refresh periods.
///
/// The compositor repaints all its visible surfaces in one scanout and flushes
/// their `done` events in one write, so one `wl_display.dispatch` carries one
/// frame's worth of callbacks. `service` runs once after that dispatch and fires
/// a *single* vsync — the callback on any visible surface sets the pace, hidden
/// surfaces stay silent, and the shared tick coalesces the rest.
pub const FrameClock = struct {
    ctx: *Context,
    period_ns: u64,

    /// One armed callback per surface. A hidden surface never fires (the
    /// compositor does not repaint it); it just sits armed until it reappears
    /// and its next commit is composited.
    surfaces: std.ArrayListUnmanaged(Entry) = .empty,

    /// The freshest repaint any surface reported, cached until `service` fires
    /// it. Overwritten on every callback so a stale frame is dropped, not fired.
    tick: ?VsyncTimes = null,

    /// Whether the first tick has been answered from our own clock, which is all
    /// it takes to get the first frame on screen.
    bootstrapped: bool = false,

    timer: ev.Timer = .init(.none),
    timer_armed: bool = false,

    const Entry = struct {
        surface: *wl.Surface,
        callback: ?*wl.Callback = null,
    };

    pub fn init(ctx: *Context, period_ns: u64) !*FrameClock {
        const self = try ctx.allocator.create(FrameClock);
        self.* = .{ .ctx = ctx, .period_ns = period_ns };
        self.timer.c.userdata = self;
        self.timer.c.callback = onTimeout;
        return self;
    }

    pub fn deinit(self: *FrameClock) void {
        self.clearTimer();
        for (self.surfaces.items) |entry| {
            if (entry.callback) |cb| cb.destroy();
        }
        self.surfaces.deinit(self.ctx.allocator);
        self.ctx.allocator.destroy(self);
    }

    pub fn setPeriod(self: *FrameClock, period_ns: u64) void {
        self.period_ns = period_ns;
    }

    /// Listen to a surface. Its callback is armed lazily by `service`.
    pub fn addSurface(self: *FrameClock, surface: *wl.Surface) !void {
        try self.surfaces.append(self.ctx.allocator, .{ .surface = surface });
    }

    /// Stop listening to a surface and drop its in-flight callback. Call before
    /// the surface itself is destroyed.
    pub fn removeSurface(self: *FrameClock, surface: *wl.Surface) void {
        for (self.surfaces.items, 0..) |entry, i| {
            if (entry.surface == surface) {
                if (entry.callback) |cb| cb.destroy();
                _ = self.surfaces.swapRemove(i);
                return;
            }
        }
    }

    /// Answer the engine when it is waiting for the display's next refresh.
    /// Called once after every dispatch (and platform wake).
    pub fn service(self: *FrameClock) void {
        // Keep a callback armed on every surface so a repaint on any of them is
        // reported. Idempotent; also picks up newly added surfaces.
        for (self.surfaces.items) |*entry| self.arm(entry);

        if (!self.ctx.eng.hasVsyncRequests()) return;

        // A repaint already happened: answer from it. This is the coalescing —
        // all of one frame's callbacks overwrote the same tick, and we fire it
        // exactly once here.
        if (self.tick != null) {
            self.fireTick();
            return;
        }

        // The first frame has not been presented yet, so the compositor has
        // nothing to time and need not answer a frame request at all. Answer
        // once from our own clock so the engine draws that first frame.
        if (!self.bootstrapped) {
            self.bootstrapped = true;
            const now = self.ctx.eng.currentTime();
            self.ctx.eng.fireVsync(now, now + self.period_ns);
            return;
        }

        // No surface has reported yet. The timer keeps us alive: it fires vsync
        // from our own clock so the engine keeps committing, and a surface that
        // reappears then has a live callback to report.
        self.armTimer();
    }

    fn arm(self: *FrameClock, entry: *Entry) void {
        if (entry.callback != null) return;

        const callback = entry.surface.frame() catch |err| {
            std.debug.print("fembed: wl_surface.frame failed: {}\n", .{err});
            return;
        };
        callback.setListener(*FrameClock, onFrame, self);
        entry.callback = callback;
    }

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

    fn fireTick(self: *FrameClock) void {
        const tick = self.tick.?;
        self.tick = null;
        self.ctx.eng.fireVsync(tick.start_ns, tick.target_ns);
    }

    /// The compositor saying one surface was repainted. Record it (do not fire);
    /// `service` fires it, coalescing every surface of the same scanout into one
    /// vsync.
    fn onFrame(callback: *wl.Callback, event: wl.Callback.Event, self: *FrameClock) void {
        switch (event) {
            .done => {
                self.tick = vsyncTimes(self.ctx.eng.currentTime(), self.period_ns);
                self.clearTimer();
                for (self.surfaces.items) |*entry| {
                    if (entry.callback == callback) {
                        entry.callback = null;
                        callback.destroy();
                        self.arm(entry); // re-arm so the next commit is tracked
                        break;
                    }
                }
            },
        }
    }

    /// No frame tick arrived within two refresh periods. The frame request stays
    /// armed, but the engine gets a tick from our own clock so it does not
    /// stall, and keeps committing so a reappearing surface can resume.
    fn onTimeout(_: *ev.Loop, c: *ev.Completion) void {
        const self: *FrameClock = @ptrCast(@alignCast(c.userdata.?));
        self.timer_armed = false;

        if (!self.ctx.eng.hasVsyncRequests()) return;
        if (self.tick != null) return self.service();

        const now = self.ctx.eng.currentTime();
        self.ctx.eng.fireVsync(now, now + self.period_ns);
    }
};

const VsyncTimes = struct { start_ns: u64, target_ns: u64 };

/// The frame timestamps to hand back to the engine, in the engine's own clock:
/// the start is "now" and the target one refresh later. The compositor's frame
/// callback time is deliberately not used for the start: it is truncated to
/// whole milliseconds, and mixing it with the engine's nanosecond clock makes
/// the reported start step backwards, which the engine rejects.
fn vsyncTimes(now_ns: u64, period_ns: u64) VsyncTimes {
    return .{ .start_ns = now_ns, .target_ns = now_ns + period_ns };
}

test "the vsync timestamps are the engine's clock, target one refresh ahead" {
    const testing = std.testing;

    const period = 6_060_238;
    const now: u64 = 10 * std.time.ns_per_ms;
    const times = vsyncTimes(now, period);
    try testing.expectEqual(now, times.start_ns);
    try testing.expectEqual(now + period, times.target_ns);
}
