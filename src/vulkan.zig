const std = @import("std");
const vk = @import("vulkan");

const instance_extensions = [_][*:0]const u8{
    vk.instance_extensions.khr_surface.name.ptr,
    vk.instance_extensions.khr_wayland_surface.name.ptr,
};

const device_extensions = [_][*:0]const u8{
    vk.device_extensions.khr_swapchain.name.ptr,
};

const api_version = vk.API_VERSION_1_3;

pub const Context = struct {
    allocator: std.mem.Allocator,
    lib: std.DynLib,
    vkb: vk.BaseWrapper,
    instance: vk.Instance,
    vki: vk.InstanceWrapper,
    pdev: vk.PhysicalDevice,
    device: vk.Device,
    vkd: vk.DeviceWrapper,
    queue: vk.Queue,
    queue_family: u32,

    pub fn init(allocator: std.mem.Allocator) !Context {
        var lib = try std.DynLib.open("libvulkan.so.1");
        errdefer lib.close();

        const get_instance_proc_addr = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
            return error.NoVulkanLoader;

        var self: Context = undefined;
        self.allocator = allocator;
        self.lib = lib;
        self.vkb = vk.BaseWrapper.load(get_instance_proc_addr);

        self.instance = try self.vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = "fembed",
                .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
                .p_engine_name = "fembed",
                .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
                .api_version = api_version.toU32(),
            },
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
            .enabled_extension_count = instance_extensions.len,
            .pp_enabled_extension_names = @ptrCast(&instance_extensions),
        }, null);

        self.vki = vk.InstanceWrapper.load(self.instance, get_instance_proc_addr);
        errdefer self.vki.destroyInstance(self.instance, null);

        self.pdev = try self.pickPhysicalDevice();
        self.queue_family = try self.findGraphicsQueueFamily();
        self.device = try self.createDevice();

        self.vkd = vk.DeviceWrapper.load(self.device, self.vki.dispatch.vkGetDeviceProcAddr.?);
        self.queue = self.vkd.getDeviceQueue(self.device, self.queue_family, 0);

        return self;
    }

    pub fn deinit(self: *Context) void {
        self.vkd.destroyDevice(self.device, null);
        self.vki.destroyInstance(self.instance, null);
        self.lib.close();
    }

    fn pickPhysicalDevice(self: *Context) !vk.PhysicalDevice {
        const pdevs = try self.vki.enumeratePhysicalDevicesAlloc(self.instance, self.allocator);
        defer self.allocator.free(pdevs);

        for (pdevs) |pdev| {
            const exts = try self.vki.enumerateDeviceExtensionPropertiesAlloc(pdev, null, self.allocator);
            defer self.allocator.free(exts);

            var has_swapchain = false;
            for (exts) |ext| {
                if (std.mem.eql(u8, std.mem.sliceTo(&ext.extension_name, 0), "VK_KHR_swapchain")) {
                    has_swapchain = true;
                    break;
                }
            }
            if (has_swapchain) return pdev;
        }

        return error.NoSuitablePhysicalDevice;
    }

    fn findGraphicsQueueFamily(self: *Context) !u32 {
        const families = try self.vki.getPhysicalDeviceQueueFamilyPropertiesAlloc(self.pdev, self.allocator);
        defer self.allocator.free(families);

        for (families, 0..) |props, i| {
            if (props.queue_flags.graphics) return @intCast(i);
        }

        return error.NoGraphicsQueueFamily;
    }

    fn createDevice(self: *Context) !vk.Device {
        const priority = [_]f32{1.0};
        const qci = [_]vk.DeviceQueueCreateInfo{
            .{
                .queue_family_index = self.queue_family,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            },
        };

        return self.vki.createDevice(self.pdev, &.{
            .queue_create_info_count = 1,
            .p_queue_create_infos = &qci,
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = @ptrCast(&device_extensions),
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = null,
        }, null);
    }
};

pub const Surface = struct {
    ctx: *Context,
    surface: vk.SurfaceKHR,
    swapchain: vk.SwapchainKHR,
    format: vk.Format,
    images: []vk.Image,
    width: u32,
    height: u32,

    pub fn create(ctx: *Context, wl_display: *anyopaque, wl_surface: *anyopaque, width: u32, height: u32) !Surface {
        const surface = try ctx.vki.createWaylandSurfaceKHR(ctx.instance, &.{
            .display = @ptrCast(@alignCast(wl_display)),
            .surface = @ptrCast(@alignCast(wl_surface)),
        }, null);
        errdefer ctx.vki.destroySurfaceKHR(ctx.instance, surface, null);

        const caps = try ctx.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.pdev, surface);
        const format = try chooseSurfaceFormat(ctx, surface);
        const present_mode: vk.PresentModeKHR = .fifo_khr;

        const extent = vk.Extent2D{
            .width = std.math.clamp(width, caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(height, caps.min_image_extent.height, caps.max_image_extent.height),
        };

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count != 0 and image_count > caps.max_image_count) image_count = caps.max_image_count;

        const swapchain = try ctx.vkd.createSwapchainKHR(ctx.device, &.{
            .surface = surface,
            .min_image_count = image_count,
            .image_format = format,
            .image_color_space = .srgb_nonlinear_khr,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{
                .color_attachment = true,
                .transfer_src = true,
                .transfer_dst = true,
                .sampled = true,
            },
            .image_sharing_mode = .exclusive,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_khr = true },
            .present_mode = present_mode,
            .clipped = .true,
        }, null);
        errdefer ctx.vkd.destroySwapchainKHR(ctx.device, swapchain, null);

        var n: u32 = 0;
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain, &n, null);
        const images = try ctx.allocator.alloc(vk.Image, n);
        errdefer ctx.allocator.free(images);
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain, &n, images.ptr);

        return .{
            .ctx = ctx,
            .surface = surface,
            .swapchain = swapchain,
            .format = format,
            .images = images,
            .width = extent.width,
            .height = extent.height,
        };
    }

    pub fn destroy(self: *Surface) void {
        self.ctx.vkd.destroySwapchainKHR(self.ctx.device, self.swapchain, null);
        self.ctx.vki.destroySurfaceKHR(self.ctx.instance, self.surface, null);
        self.ctx.allocator.free(self.images);
    }

    /// Returns the index of the acquired swapchain image.
    pub fn acquire(self: *Surface) !u32 {
        try self.ctx.vkd.deviceWaitIdle(self.ctx.device);
        const result = try self.ctx.vkd.acquireNextImageKHR(
            self.ctx.device,
            self.swapchain,
            std.math.maxInt(u64),
            .null,
            .null,
        );
        return result.image_index;
    }

    pub fn present(self: *Surface, image: vk.Image) !void {
        const index = for (self.images, 0..) |img, i| {
            if (img == image) break @as(u32, @intCast(i));
        } else return error.UnknownImage;

        const present_info = vk.PresentInfoKHR{
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&index),
        };
        _ = try self.ctx.vkd.queuePresentKHR(self.ctx.queue, &present_info);
    }

    fn chooseSurfaceFormat(ctx: *Context, surface: vk.SurfaceKHR) !vk.Format {
        const formats = try ctx.vki.getPhysicalDeviceSurfaceFormatsAllocKHR(ctx.pdev, surface, ctx.allocator);
        defer ctx.allocator.free(formats);

        for (formats) |f| {
            if (f.format == .b8g8r8a8_unorm and f.color_space == .srgb_nonlinear_khr) {
                return f.format;
            }
        }
        return formats[0].format;
    }
};
