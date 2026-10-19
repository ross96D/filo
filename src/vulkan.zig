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

/// A swapchain and the images it holds. `Surface` swaps one of these out for
/// another when the window changes size.
const Swapchain = struct {
    handle: vk.SwapchainKHR,
    format: vk.Format,
    images: []vk.Image,
    /// Extent it was created with. The driver may clamp what we ask for, so this
    /// is not necessarily the size the engine draws at.
    extent: vk.Extent2D,

    fn destroy(self: Swapchain, ctx: *Context) void {
        ctx.vkd.destroySwapchainKHR(ctx.device, self.handle, null);
        ctx.allocator.free(self.images);
    }
};

/// What the engine needs to draw a frame: the image to render into, and the
/// format it was created with.
pub const Frame = struct {
    image: vk.Image,
    format: vk.Format,
};

pub const Surface = struct {
    ctx: *Context,
    surface: vk.SurfaceKHR,
    /// The swapchain to draw into. Null only between a failed rebuild and the
    /// next frame's attempt at one: with no swapchain there is nothing to draw
    /// into, so that frame is dropped.
    swapchain: ?Swapchain = null,
    /// The size the engine last drew at, from `FlutterFrameInfo`. Tracked
    /// separately from `Swapchain.extent` so that a clamped extent cannot make
    /// every frame rebuild with the same result.
    frame_size: vk.Extent2D,
    /// Set when the swapchain no longer matches the surface: a suboptimal
    /// present, or an out-of-date acquire. It is rebuilt on the next frame.
    stale: bool = false,

    pub fn create(ctx: *Context, wl_display: *anyopaque, wl_surface: *anyopaque, width: u32, height: u32) !Surface {
        const surface = try ctx.vki.createWaylandSurfaceKHR(ctx.instance, &.{
            .display = @ptrCast(@alignCast(wl_display)),
            .surface = @ptrCast(@alignCast(wl_surface)),
        }, null);
        errdefer ctx.vki.destroySurfaceKHR(ctx.instance, surface, null);

        const size = vk.Extent2D{ .width = width, .height = height };
        return .{
            .ctx = ctx,
            .surface = surface,
            .swapchain = try buildSwapchain(ctx, surface, size),
            .frame_size = size,
        };
    }

    /// Make the swapchain match the size the engine is drawing at, if it does
    /// not already (or if a previous frame found it stale). Runs at the start of
    /// every frame, and does nothing at all when there is nothing to do.
    fn resize(self: *Surface, size: vk.Extent2D) !void {
        if (self.swapchain != null and !self.stale and
            size.width == self.frame_size.width and size.height == self.frame_size.height) return;
        // A zero-sized frame is not a size the compositor can have asked for,
        // and not a valid swapchain: leave the current one in place.
        if (size.width == 0 or size.height == 0) return;

        // The old swapchain goes first: a driver rejects a second one for the
        // same surface (`VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`), which is what
        // passing it as `oldSwapchain` avoids, but that way a failed create
        // retires the old swapchain too, so it cannot be kept as a fallback
        // either. Nothing is in flight here, `acquire` has waited for the device
        // to go idle.
        if (self.swapchain) |swapchain| swapchain.destroy(self.ctx);
        self.swapchain = null;

        const built = try buildSwapchain(self.ctx, self.surface, size);
        // The driver may have picked a different size than the one asked for,
        // and this is the size the surface will have, not the one the engine
        // draws at: worth saying out loud.
        if (built.extent.width != size.width or built.extent.height != size.height) {
            std.debug.print("fembed: swapchain is {}x{}, not {}x{}\n", .{
                built.extent.width,
                built.extent.height,
                size.width,
                size.height,
            });
        }

        self.swapchain = built;
        self.frame_size = size;
        self.stale = false;
    }

    /// Build a swapchain and the images it holds. The extent is clamped to what
    /// the surface supports, so it can differ from `size`, which is what the
    /// engine draws at.
    fn buildSwapchain(ctx: *Context, surface: vk.SurfaceKHR, size: vk.Extent2D) !Swapchain {
        const caps = try ctx.vki.getPhysicalDeviceSurfaceCapabilitiesKHR(ctx.pdev, surface);
        const extent = swapchainExtent(size, caps);
        const format = try chooseSurfaceFormat(ctx, surface);

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
            .present_mode = .fifo_khr,
            .clipped = .true,
        }, null);
        errdefer ctx.vkd.destroySwapchainKHR(ctx.device, swapchain, null);

        var n: u32 = 0;
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain, &n, null);
        const images = try ctx.allocator.alloc(vk.Image, n);
        errdefer ctx.allocator.free(images);
        _ = try ctx.vkd.getSwapchainImagesKHR(ctx.device, swapchain, &n, images.ptr);

        return .{ .handle = swapchain, .format = format, .images = images, .extent = extent };
    }

    pub fn destroy(self: *Surface) void {
        if (self.swapchain) |swapchain| swapchain.destroy(self.ctx);
        self.ctx.vki.destroySurfaceKHR(self.ctx.instance, self.surface, null);
    }

    /// Acquire an image for a frame the engine is drawing at `width`×`height`
    /// (its `FlutterFrameInfo`). The swapchain is rebuilt first when that size
    /// changed, or when a previous frame found it stale.
    ///
    /// This and `present` run on the engine's render thread, one frame at a
    /// time, so none of this state needs to be locked against the event loop:
    /// the loop only sends window metrics, it never touches the swapchain.
    pub fn acquire(self: *Surface, width: u32, height: u32) !Frame {
        const size = vk.Extent2D{ .width = width, .height = height };

        var retried = false;
        while (true) {
            try self.resize(size);
            const swapchain = self.swapchain orelse return error.NoSwapchain;

            try self.ctx.vkd.deviceWaitIdle(self.ctx.device);
            const acquired = self.ctx.vkd.acquireNextImageKHR(
                self.ctx.device,
                swapchain.handle,
                std.math.maxInt(u64),
                .null,
                .null,
            ) catch |err| switch (err) {
                // The surface moved on without a configure telling us to (an
                // output scale change, for instance): rebuild for the same size
                // and try once more.
                error.OutOfDateKHR => {
                    if (retried) return err;
                    retried = true;
                    self.stale = true;
                    continue;
                },
                else => return err,
            };

            // Usable for this frame, but not for the next one.
            if (acquired.result == .suboptimal_khr) self.stale = true;
            return .{ .image = swapchain.images[acquired.image_index], .format = swapchain.format };
        }
    }

    pub fn present(self: *Surface, image: vk.Image) !void {
        const swapchain = self.swapchain orelse return error.NoSwapchain;
        const index = for (swapchain.images, 0..) |img, i| {
            if (img == image) break @as(u32, @intCast(i));
        } else return error.UnknownImage;

        const present_info = vk.PresentInfoKHR{
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&swapchain.handle),
            .p_image_indices = @ptrCast(&index),
        };
        const presented = self.ctx.vkd.queuePresentKHR(self.ctx.queue, &present_info) catch |err| switch (err) {
            // The frame was not shown. The image belongs to a swapchain that is
            // about to be rebuilt, so there is nothing left to present.
            error.OutOfDateKHR => {
                self.stale = true;
                return err;
            },
            else => return err,
        };

        if (presented == .suboptimal_khr) self.stale = true;
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

/// The extent to create a swapchain at: the size the engine is drawing at,
/// clamped to what the surface supports. The Wayland compositor takes the
/// surface size from the buffers we attach, and `current_extent` only reports
/// the size of the last one, so it is not a size to resize to.
fn swapchainExtent(size: vk.Extent2D, caps: vk.SurfaceCapabilitiesKHR) vk.Extent2D {
    return .{
        .width = std.math.clamp(@max(size.width, 1), caps.min_image_extent.width, caps.max_image_extent.width),
        .height = std.math.clamp(@max(size.height, 1), caps.min_image_extent.height, caps.max_image_extent.height),
    };
}

fn expectExtent(expected: vk.Extent2D, actual: vk.Extent2D) !void {
    try std.testing.expectEqual(expected.width, actual.width);
    try std.testing.expectEqual(expected.height, actual.height);
}

test "the swapchain follows the frame size, clamped to what the surface supports" {
    var caps = std.mem.zeroes(vk.SurfaceCapabilitiesKHR);
    caps.min_image_extent = .{ .width = 2, .height = 2 };
    caps.max_image_extent = .{ .width = 4096, .height = 4096 };

    try expectExtent(.{ .width = 800, .height = 600 }, swapchainExtent(.{ .width = 800, .height = 600 }, caps));
    // Never a zero-sized swapchain, even if the engine asks for one.
    try expectExtent(.{ .width = 2, .height = 2 }, swapchainExtent(.{ .width = 0, .height = 0 }, caps));
    // Outside the surface limits.
    try expectExtent(.{ .width = 2, .height = 2 }, swapchainExtent(.{ .width = 1, .height = 1 }, caps));
    try expectExtent(.{ .width = 4096, .height = 4096 }, swapchainExtent(.{ .width = 8000, .height = 6000 }, caps));
}
