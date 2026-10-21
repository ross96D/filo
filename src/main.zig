const std = @import("std");

const zio = @import("zio");
const ev = zio.ev;

const c = @import("flutter");
const vk = @import("vulkan");

const engine = @import("engine.zig");
const connection = @import("wayland/connection.zig");
const window = @import("wayland/window.zig");
const frame_clock = @import("wayland/frame_clock.zig");
const context = @import("context.zig");
const manifest = @import("manifest.zig");
const vulkan = @import("vulkan.zig");
const input = @import("input.zig");
const text_input = @import("flutter/text_input.zig");
const platform_handler = @import("flutter/platform_handler.zig");
const platform_channel = @import("flutter/platform_channel.zig");

/// The one struct the callbacks reach into: it is the engine's `user_data`
/// (the Vulkan callbacks reach the view, the platform message callback the
/// channels) and the loop sources' context (the display and task eventfd
/// callbacks reach the globals in `ctx` plus the window and frame clock).
const App = struct {
    ctx: context.Context,
    win: *window.Window,
    frame: *frame_clock.FrameClock,
    view: VulkanView,
    /// Read by the vsync callback on the engine's raster thread, so it is
    /// written before the engine can ask for a frame and cleared under the same
    /// atomic when it is torn down.
    engine: std.atomic.Value(?*engine.Engine) = std.atomic.Value(?*engine.Engine).init(null),
    channels: platform_channel.Registry,

    display_probe: ev.PipePoll = .init(-1, .read),
    platform_probe: ev.PipePoll = .init(-1, .read),
    err: ?anyerror = null,
};

const VulkanView = struct {
    ctx: vulkan.Context,
    surface: vulkan.Surface,

    fn getInstanceProcAddr(
        user_data: ?*anyopaque,
        instance: c.FlutterVulkanInstanceHandle,
        name: [*c]const u8,
    ) callconv(.c) ?*anyopaque {
        const self = &(@as(*App, @ptrCast(@alignCast(user_data))).view);
        const vk_instance: vk.Instance = @ptrCast(instance);
        const name_z: [*:0]const u8 = @ptrCast(name);
        const fnptr = self.ctx.vkb.dispatch.vkGetInstanceProcAddr.?(vk_instance, name_z);
        const p = fnptr orelse return null;
        return @ptrCast(@constCast(p));
    }

    fn getNextImage(
        user_data: ?*anyopaque,
        frame_info: [*c]const c.FlutterFrameInfo,
    ) callconv(.c) c.FlutterVulkanImage {
        const self = &(@as(*App, @ptrCast(@alignCast(user_data))).view);
        // The engine tells us the size it drew at, which is the size the
        // swapchain has to be. A zero image tells the engine the frame was lost.
        const size = frame_info.*.size;
        const frame = self.surface.acquire(size.width, size.height) catch |e| {
            std.debug.print("fembed: vulkan frame unavailable: {}\n", .{e});
            return std.mem.zeroes(c.FlutterVulkanImage);
        };
        return .{
            .struct_size = @sizeOf(c.FlutterVulkanImage),
            .image = @backingInt(frame.image),
            .format = @intCast(@backingInt(frame.format)),
        };
    }

    fn presentImage(
        user_data: ?*anyopaque,
        image: [*c]const c.FlutterVulkanImage,
    ) callconv(.c) bool {
        const self = &(@as(*App, @ptrCast(@alignCast(user_data))).view);
        const vk_image: vk.Image = @fromBackingInt(@intCast(image.*.image));
        self.surface.present(vk_image) catch |e| {
            std.debug.print("fembed: vulkan present failed: {}\n", .{e});
            return false;
        };
        return true;
    }

    fn rendererConfig(self: *VulkanView) c.FlutterRendererConfig {
        var config: c.FlutterRendererConfig = undefined;
        config.type = c.kVulkan;
        config.unnamed_0.vulkan = .{
            .struct_size = @sizeOf(c.FlutterVulkanRendererConfig),
            .version = vk.API_VERSION_1_3.toU32(),
            .instance = @ptrCast(self.ctx.instance),
            .physical_device = @ptrCast(self.ctx.pdev),
            .device = @ptrCast(self.ctx.device),
            .queue_family_index = self.ctx.queue_family,
            .queue = @ptrCast(self.ctx.queue),
            .enabled_instance_extension_count = vulkan.instance_extensions.len,
            .enabled_instance_extensions = @ptrCast(@constCast(&vulkan.instance_extensions)),
            .enabled_device_extension_count = vulkan.device_extensions.len,
            .enabled_device_extensions = @ptrCast(@constCast(&vulkan.device_extensions)),
            .get_instance_proc_address_callback = getInstanceProcAddr,
            .get_next_image_callback = getNextImage,
            .present_image_callback = presentImage,
        };
        return config;
    }
};

/// Invoked by the engine (on the engine thread) for every platform message the
/// framework sends to the embedder. Every message must be answered; the actual
/// routing lives in `flutter/platform_channel.zig`.
fn platformMessageCallback(
    message: [*c]const c.FlutterPlatformMessage,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    app.channels.handle(message);
}

/// Invoked by the engine on its raster thread when it wants to start a frame at
/// the display's next refresh. It hands back a baton, and the engine waits for
/// it; `FlutterEngineOnVsync` may only be called on the main thread, so the
/// baton is queued for the event loop, which answers it from the compositor's
/// frame clock.
fn vsyncCallback(user_data: ?*anyopaque, baton: isize) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    // Set before the engine is initialized, so this is never null while it can
    // be called; it is only cleared once the engine is being torn down.
    const eng = app.engine.load(.acquire) orelse return;
    eng.requestVsync(baton);
}

/// The compositor has something for us. `dispatch` reads and dispatches it;
/// the fd was reported readable, so the wait inside it returns at once.
fn onDisplayReadable(loop: *ev.Loop, completion: *ev.Completion) void {
    const app: *App = @ptrCast(@alignCast(completion.userdata.?));
    app.ctx.conn.dispatch() catch |err| return fail(app, loop, err);
    afterDispatch(app, loop);
}

/// The engine has platform tasks to run on this thread, or a vsync request to
/// answer. Both are dealt with before returning to the loop.
fn onPlatformWake(loop: *ev.Loop, completion: *ev.Completion) void {
    const app: *App = @ptrCast(@alignCast(completion.userdata.?));
    app.ctx.eng.drainPlatformTasks();
    afterDispatch(app, loop);
}

/// Work the loop owes after any wake: a resize the compositor asked for, a tick
/// the engine is waiting on, and the requests those queued on the connection.
fn afterDispatch(self: *App, loop: *ev.Loop) void {
    if (self.win.closing) {
        loop.stop();
        return;
    }
    self.win.applyResize(self.ctx.eng);
    self.ctx.eng.frame_period_ns = self.ctx.conn.frame_period_ns;
    self.frame.setPeriod(self.ctx.conn.frame_period_ns);
    self.frame.service();
    self.ctx.conn.flush();
}

/// A callback cannot hand an error back to the loop, so remember it and stop;
/// `main` returns it once the loop comes back.
fn fail(self: *App, loop: *ev.Loop, err: anyerror) void {
    self.err = err;
    loop.stop();
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const cfg = try manifest.load(init.environ_map);

    const conn = try connection.Connection.connect(allocator);
    defer conn.deinit();

    const win = try conn.createWindow();
    defer win.destroy(allocator);

    try conn.waitReady(win);

    // The one loop in the program. Everything below registers a descriptor or
    // a timer with it and does its work from a callback.
    var loop: zio.ev.Loop = undefined;
    try loop.init(.{ .allocator = allocator });
    defer loop.deinit();

    var vk_ctx = try vulkan.Context.init(allocator, .{
        .validation = init.environ_map.get("FEMBED_VULKAN_VALIDATION") != null,
        .trace = init.environ_map.get("FEMBED_TRACE") != null,
    });
    defer vk_ctx.deinit();

    var app = App{
        .view = .{
            .ctx = vk_ctx,
            .surface = try vulkan.Surface.create(&vk_ctx, @ptrCast(conn.display), @ptrCast(win.surface), win.width, win.height),
        },
        .channels = platform_channel.Registry.init(allocator),
        .win = win,
        .ctx = undefined,
        .frame = undefined,
    };
    defer app.channels.deinit();
    defer app.view.surface.destroy();

    const renderer = app.view.rendererConfig();

    const eng = try engine.Engine.init(
        allocator,
        cfg,
        &renderer,
        &app,
        &app.engine,
        platformMessageCallback,
        vsyncCallback,
    );
    defer eng.deinit(allocator);
    app.channels.eng = eng;

    // The globals are only complete once the engine exists.
    app.ctx = .{ .allocator = allocator, .loop = &loop, .conn = conn, .eng = eng };
    app.frame = try frame_clock.FrameClock.init(&app.ctx, win.surface, conn.frame_period_ns);
    defer app.frame.deinit();

    var ti = text_input.TextInput.init(allocator, eng);
    defer ti.deinit();
    app.channels.text_input = &ti;

    var inp = try input.Input.init(eng, &ti);
    defer inp.deinit();
    try conn.bindSeat(&app.ctx, &inp);

    var ph = platform_handler.PlatformHandler.init(allocator, eng, conn.clipboard.?, &loop);
    defer ph.deinit();
    ph.attach();
    app.channels.platform = &ph;

    eng.sendWindowMetrics(win.width, win.height, win.pixel_ratio);
    // Without this the engine has no display at all and falls back for the
    // refresh rate it derives its frame budget from.
    if (conn.refresh_mhz != 0) {
        eng.notifyDisplayStartup(.{
            .refresh_rate = @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
            .width = conn.display_width,
            .height = conn.display_height,
            .pixel_ratio = win.pixel_ratio,
        });
        std.debug.print("fembed: display {}x{} at {d:.3} Hz\n", .{
            conn.display_width,
            conn.display_height,
            @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
        });
    }

    // The loop's two sources: the display fd and the engine's task eventfd.
    app.display_probe = .init(conn.getFd(), .read);
    app.display_probe.c.userdata = &app;
    app.display_probe.c.callback = onDisplayReadable;
    app.display_probe.c.flags.rearm = true;
    loop.add(&app.display_probe.c);

    app.platform_probe = .init(eng.getPlatformEventFd(), .read);
    app.platform_probe.c.userdata = &app;
    app.platform_probe.c.callback = onPlatformWake;
    app.platform_probe.c.flags.rearm = true;
    loop.add(&app.platform_probe.c);

    std.debug.print("fembed: window created, entering event loop\n", .{});
    try loop.run();
    if (app.err) |err| return err;
}
