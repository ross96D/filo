const std = @import("std");

const c = @import("flutter");
const vk = @import("vulkan");

const engine = @import("engine.zig");
const window = @import("window.zig");
const manifest = @import("manifest.zig");
const vulkan = @import("vulkan.zig");
const input = @import("input.zig");
const text_input = @import("flutter/text_input.zig");
const platform_handler = @import("flutter/platform_handler.zig");
const platform_channel = @import("flutter/platform_channel.zig");

/// Shared `user_data` for the engine: the Vulkan renderer callbacks need the
/// view, while the platform message callback needs the channel registry. Both
/// are reached from this one pointer, because the engine only takes a single
/// `user_data`.
const App = struct {
    view: VulkanView,
    /// Read by the vsync callback on the engine's raster thread, so it is
    /// written before the engine can ask for a frame and cleared under the same
    /// atomic when it is torn down.
    engine: std.atomic.Value(?*engine.Engine) = std.atomic.Value(?*engine.Engine).init(null),
    channels: platform_channel.Registry,
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
            .enabled_instance_extension_count = 0,
            .enabled_instance_extensions = null,
            .enabled_device_extension_count = 0,
            .enabled_device_extensions = null,
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const cfg = try manifest.load(init.environ_map);

    const win = try window.Window.create(allocator);
    defer win.destroy();
    try win.waitConfigured();

    var ctx = try vulkan.Context.init(allocator, .{
        .validation = init.environ_map.get("FEMBED_VULKAN_VALIDATION") != null,
        .trace = init.environ_map.get("FEMBED_TRACE") != null,
    });
    defer ctx.deinit();

    var app = App{
        .view = .{
            .ctx = ctx,
            .surface = try vulkan.Surface.create(&ctx, @ptrCast(win.display), @ptrCast(win.surface), win.width, win.height),
        },
        .channels = platform_channel.Registry.init(allocator),
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
    defer eng.deinit();
    app.channels.eng = eng;

    var ti = text_input.TextInput.init(allocator, eng);
    defer ti.deinit();
    app.channels.text_input = &ti;

    var inp = try input.Input.init(eng, &ti);
    defer inp.deinit();
    try win.setupInput(&inp);

    // `setupInput` creates the clipboard, which needs a seat to exist.
    var ph = platform_handler.PlatformHandler.init(allocator, eng, win.clipboard.?, &win.running);
    defer ph.deinit();
    ph.attach();
    app.channels.platform = &ph;

    eng.sendWindowMetrics(win.width, win.height, win.pixel_ratio);
    // Without this the engine has no display at all and falls back for the
    // refresh rate it derives its frame budget from.
    if (win.refresh_mhz != 0) {
        eng.notifyDisplayStartup(.{
            .refresh_rate = @as(f64, @floatFromInt(win.refresh_mhz)) / 1000.0,
            .width = win.display_width,
            .height = win.display_height,
            .pixel_ratio = win.pixel_ratio,
        });
        std.debug.print("fembed: display {}x{} at {d:.3} Hz\n", .{
            win.display_width,
            win.display_height,
            @as(f64, @floatFromInt(win.refresh_mhz)) / 1000.0,
        });
    }

    std.debug.print("fembed: window created, entering event loop\n", .{});
    try win.run(eng);
}
