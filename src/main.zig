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
    /// Filled in before the engine is initialized. Its `user_data` is the
    /// `VulkanView`, which the backing-store and present callbacks reach into.
    compositor: c.FlutterCompositor = undefined,

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

    /// `FlutterVulkanRendererConfig` requires these callbacks to be non-null,
    /// but the compositor path never calls them: the engine renders into
    /// backing stores and `presentView` composites those.
    fn unusedNextImage(
        user_data: ?*anyopaque,
        frame_info: [*c]const c.FlutterFrameInfo,
    ) callconv(.c) c.FlutterVulkanImage {
        _ = user_data;
        _ = frame_info;
        @panic("calling next image from renderer but should call the flutter compositor callbacks");
    }

    fn unusedPresentImage(
        user_data: ?*anyopaque,
        image: [*c]const c.FlutterVulkanImage,
    ) callconv(.c) bool {
        _ = user_data;
        _ = image;
        @panic("calling present image from renderer but should call the flutter compositor callbacks");
    }

    /// The engine has finished rendering a view into backing-store images. Blit
    /// them onto the view's swapchain and present it.
    fn presentView(self: *VulkanView, info: [*c]const c.FlutterPresentViewInfo) bool {
        if (info == null) return false;

        // One layer per Flutter view, plus platform views if the app uses them.
        // The engine does not put a hard limit on the count, but a frame with
        // more layers than this is not something this embedder can composite.
        var layers: [16]vulkan.Layer = undefined;
        var count: usize = 0;
        var width: u32 = 0;
        var height: u32 = 0;

        for (info.*.layers[0..info.*.layers_count]) |layer_ptr| {
            const layer = layer_ptr.*;
            if (layer.type != @as(c.FlutterLayerContentType, @intCast(c.kFlutterLayerContentTypeBackingStore))) continue;
            const backing_store = layer.unnamed_0.backing_store;
            if (backing_store == null or backing_store.*.user_data == null) continue;

            const holder: *VulkanBackingStore = @ptrCast(@alignCast(backing_store.*.user_data.?));
            width = @max(width, holder.store.extent.width);
            height = @max(height, holder.store.extent.height);
            if (count < layers.len) {
                layers[count] = .{
                    .image = holder.store.image,
                    .extent = holder.store.extent,
                };
                count += 1;
            }
        }

        // A frame with no backing-store layer still has to show something. Use
        // the last size the engine drew at; before any frame there is nothing
        // to present at all.
        if (width == 0 or height == 0) {
            width = self.surface.frame_size.width;
            height = self.surface.frame_size.height;
        }
        if (width == 0 or height == 0) return true;

        self.surface.presentLayers(width, height, layers[0..count]) catch |e| {
            std.debug.print("fembed: compositor present failed: {}\n", .{e});
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
            .get_next_image_callback = unusedNextImage,
            .present_image_callback = unusedPresentImage,
        };
        return config;
    }
};

/// The embedder's side of a `FlutterBackingStore`: the Vulkan image the engine
/// renders into, and the description it is handed through to the engine. The
/// pointer must remain stable while the engine caches the store.
const VulkanBackingStore = struct {
    store: vulkan.BackingStore,
    image: c.FlutterVulkanImage,
};

/// The engine needs a render target for a view. Allocate one that Skia can wrap
/// as a color attachment; the engine will render into it and hand it back in
/// `presentViewCallback`.
fn createBackingStore(
    config: [*c]const c.FlutterBackingStoreConfig,
    backing_store_out: [*c]c.FlutterBackingStore,
    user_data: ?*anyopaque,
) callconv(.c) bool {
    const self: *VulkanView = @ptrCast(@alignCast(user_data.?));

    const size = config.*.size;
    const extent = vk.Extent2D{
        .width = @intFromFloat(@max(size.width, 1.0)),
        .height = @intFromFloat(@max(size.height, 1.0)),
    };

    // BGRA is the format the Linux embedder uses elsewhere, and it is what the
    // swapchain prefers; the compositor blits between them when they differ.
    var store = vulkan.BackingStore.create(&self.ctx, extent, .b8g8r8a8_unorm) catch |e| {
        std.debug.print("fembed: could not create backing store: {}\n", .{e});
        return false;
    };

    const holder = std.heap.c_allocator.create(VulkanBackingStore) catch {
        store.destroy();
        return false;
    };
    holder.* = .{
        .store = store,
        .image = .{
            .struct_size = @sizeOf(c.FlutterVulkanImage),
            .image = @backingInt(store.image),
            .format = @intCast(@backingInt(store.format)),
        },
    };

    backing_store_out.* = .{
        .struct_size = @sizeOf(c.FlutterBackingStore),
        .user_data = holder,
        .type = @intCast(c.kFlutterBackingStoreTypeVulkan),
        .did_update = true,
        .unnamed_0 = .{ .vulkan = .{
            .struct_size = @sizeOf(c.FlutterVulkanBackingStore),
            .image = &holder.image,
            .user_data = holder,
            .destruction_callback = destroyBackingStore,
        } },
    };
    return true;
}

/// The engine releases the backing store. Skia calls the destruction callback
/// this store was handed with; that is where the image is freed.
fn collectBackingStore(
    backing_store: [*c]const c.FlutterBackingStore,
    user_data: ?*anyopaque,
) callconv(.c) bool {
    _ = backing_store;
    _ = user_data;
    return true;
}

fn destroyBackingStore(user_data: ?*anyopaque) callconv(.c) void {
    const holder: *VulkanBackingStore = @ptrCast(@alignCast(user_data.?));
    holder.store.destroy();
    std.heap.c_allocator.destroy(holder);
}

fn presentViewCallback(info: [*c]const c.FlutterPresentViewInfo) callconv(.c) bool {
    if (info == null or info.*.user_data == null) return false;
    const self: *VulkanView = @ptrCast(@alignCast(info.*.user_data.?));
    return self.presentView(info);
}

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

    // Impeller's Vulkan backend cannot render into compositor backing stores.
    // FORCE_IMPELLER still turns it on, which is expected to fail: this embedder
    // has no direct-to-swapchain path any more.
    app.compositor = .{
        .struct_size = @sizeOf(c.FlutterCompositor),
        .user_data = &app.view,
        .create_backing_store_callback = createBackingStore,
        .collect_backing_store_callback = collectBackingStore,
        .present_layers_callback = null,
        .avoid_backing_store_cache = false,
        .present_view_callback = presentViewCallback,
    };

    const eng = try engine.Engine.init(
        allocator,
        cfg,
        &renderer,
        &app.compositor,
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
