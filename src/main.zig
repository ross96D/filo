const std = @import("std");

const c = @import("flutter");
const vk = @import("vulkan");

const engine = @import("engine.zig");
const window = @import("window.zig");
const manifest = @import("manifest.zig");
const vulkan = @import("vulkan.zig");
const input = @import("input.zig");

const width = 800;
const height = 600;
const pixel_ratio = 1.0;

const VulkanView = struct {
    ctx: vulkan.Context,
    surface: vulkan.Surface,

    fn getInstanceProcAddr(
        user_data: ?*anyopaque,
        instance: c.FlutterVulkanInstanceHandle,
        name: [*c]const u8,
    ) callconv(.c) ?*anyopaque {
        const self: *VulkanView = @ptrCast(@alignCast(user_data));
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
        _ = frame_info;
        const self: *VulkanView = @ptrCast(@alignCast(user_data));
        const index = self.surface.acquire() catch return std.mem.zeroes(c.FlutterVulkanImage);
        const image = self.surface.images[index];
        return .{
            .struct_size = @sizeOf(c.FlutterVulkanImage),
            .image = @backingInt(image),
            .format = @intCast(@backingInt(self.surface.format)),
        };
    }

    fn presentImage(
        user_data: ?*anyopaque,
        image: [*c]const c.FlutterVulkanImage,
    ) callconv(.c) bool {
        const self: *VulkanView = @ptrCast(@alignCast(user_data));
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

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const cfg = try manifest.load(init.environ_map);

    const win = try window.Window.create(allocator);
    defer win.destroy();
    try win.waitConfigured();

    var ctx = try vulkan.Context.init(allocator);
    defer ctx.deinit();

    var view = VulkanView{
        .ctx = ctx,
        .surface = try vulkan.Surface.create(&ctx, @ptrCast(win.display), @ptrCast(win.surface), width, height),
    };
    defer view.surface.destroy();

    const renderer = view.rendererConfig();

    var eng = try engine.Engine.init(allocator, cfg, &renderer, &view);
    defer eng.deinit();

    var inp = try input.Input.init(eng);
    defer inp.deinit();
    try win.setupInput(&inp);

    eng.sendWindowMetrics(width, height, pixel_ratio);

    std.debug.print("fembed: window created, entering event loop\n", .{});
    try win.run(eng);
}
