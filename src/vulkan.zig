const std = @import("std");
const vk = @import("vulkan");

pub const instance_extensions = [_][*:0]const u8{
    vk.instance_extensions.khr_surface.name.ptr,
    vk.instance_extensions.khr_wayland_surface.name.ptr,
};

pub const device_extensions = [_][*:0]const u8{
    vk.device_extensions.khr_swapchain.name.ptr,
};

const api_version = vk.API_VERSION_1_3;

/// The one layer worth having: it turns the renderer's Vulkan misuse into
/// output instead of silence.
const validation_layer: [*:0]const u8 = "VK_LAYER_KHRONOS_validation";
const validation_layers = [_][*:0]const u8{validation_layer};

pub const Options = struct {
    /// Enable the validation layer, if it is installed.
    validation: bool = false,
    /// Print per-frame synchronization timings every 60 frames.
    trace: bool = false,
};

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: Options,
    lib: std.DynLib,
    vkb: vk.BaseWrapper,
    instance: vk.Instance,
    vki: vk.InstanceWrapper,
    pdev: vk.PhysicalDevice,
    device: vk.Device,
    vkd: vk.DeviceWrapper,
    queue: vk.Queue,
    queue_family: u32,
    /// Serializes queue submissions/presents against surface teardown. Views
    /// present on the engine's raster thread, while removing a view releases
    /// its surface from the Wayland thread; `vkDeviceWaitIdle` must not run
    /// while another thread is using the queue.
    render_mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, options: Options) !Context {
        var lib = try std.DynLib.open("libvulkan.so.1");
        errdefer lib.close();

        const get_instance_proc_addr = lib.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
            return error.NoVulkanLoader;

        var self: Context = undefined;
        self.allocator = allocator;
        self.io = io;
        self.options = options;
        self.lib = lib;
        self.render_mutex = .init;
        self.vkb = vk.BaseWrapper.load(get_instance_proc_addr);

        const layers = try self.enabledLayers();

        self.instance = try self.vkb.createInstance(&.{
            .p_application_info = &.{
                .p_application_name = "fembed",
                .application_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
                .p_engine_name = "fembed",
                .engine_version = vk.makeApiVersion(0, 1, 0, 0).toU32(),
                .api_version = api_version.toU32(),
            },
            .enabled_layer_count = @intCast(layers.len),
            .pp_enabled_layer_names = @ptrCast(layers.ptr),
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

    /// The layer names to enable. Asking for validation on a machine that does
    /// not have the layer would otherwise fail the whole instance, so check
    /// first and carry on without it.
    fn enabledLayers(self: *Context) ![]const [*:0]const u8 {
        const no_layers: []const [*:0]const u8 = &.{};
        if (!self.options.validation) return no_layers;
        if (!try self.hasLayer(validation_layer)) {
            std.debug.print("fembed: {s} is not installed, continuing without validation\n", .{validation_layer});
            return no_layers;
        }
        return &validation_layers;
    }

    fn hasLayer(self: *Context, name: [*:0]const u8) !bool {
        const props = try self.vkb.enumerateInstanceLayerPropertiesAlloc(self.allocator);
        defer self.allocator.free(props);

        for (props) |prop| {
            if (std.mem.eql(u8, std.mem.sliceTo(&prop.layer_name, 0), std.mem.span(name))) return true;
        }
        return false;
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

    fn findMemoryType(self: *Context, type_bits: u32, properties: vk.MemoryPropertyFlags) !u32 {
        const memory = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);
        for (memory.memory_types[0..memory.memory_type_count], 0..) |mem_type, i| {
            if (type_bits & (@as(u32, 1) << @truncate(i)) != 0 and
                mem_type.property_flags.contains(properties)) return @intCast(i);
        }
        return error.NoSuitableMemoryType;
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

/// Per-frame timings for the render synchronization: how long the presentation
/// engine makes us wait for an image, how long the fence for it takes, how long
/// presenting takes, and how far apart frames are. A synchronization cost that
/// is not visible anywhere else shows up here.
///
/// The acquire is the number to watch once the engine is paced by the display:
/// the wait for an image is where a frame that arrives too early spends its
/// time. Reading the clock is not free on every machine (with the HPET
/// clocksource the kernel has to be called for the time), so this costs a few
/// microseconds per frame while it is on, and is off unless `FEMBED_TRACE` asks
/// for it.
const Trace = struct {
    enabled: bool,

    frames: u32 = 0,
    acquire_ns: u64 = 0,
    acquire_max_ns: u64 = 0,
    wait_ns: u64 = 0,
    wait_max_ns: u64 = 0,
    present_ns: u64 = 0,
    present_max_ns: u64 = 0,
    interval_ns: u64 = 0,
    interval_max_ns: u64 = 0,
    last_frame_ns: u64 = 0,

    /// The window to average over. Printing every frame would cost more than
    /// what is being measured.
    const report_every = 60;

    fn init(enabled: bool) Trace {
        return .{ .enabled = enabled };
    }

    /// A timestamp for `since`: 0 when tracing is off, which makes the two
    /// calls around a phase do nothing at all.
    fn now(self: *Trace) u64 {
        if (!self.enabled) return 0;
        return monotonicNs();
    }

    fn since(self: *Trace, start: u64) u64 {
        if (!self.enabled) return 0;
        return monotonicNs() - start;
    }

    /// Record the acquire, the fence wait and the gap since the previous frame,
    /// and print the window every `report_every` frames.
    fn record(self: *Trace, acquire_ns: u64, wait_ns: u64, frame_start: u64) void {
        if (!self.enabled) return;

        accumulate(&self.acquire_ns, &self.acquire_max_ns, acquire_ns);
        accumulate(&self.wait_ns, &self.wait_max_ns, wait_ns);
        if (self.last_frame_ns != 0) {
            accumulate(&self.interval_ns, &self.interval_max_ns, frame_start - self.last_frame_ns);
        }
        self.last_frame_ns = frame_start;
        self.frames += 1;
        if (self.frames % report_every != 0) return;

        std.debug.print(
            "fembed: trace {d} frames: acquire avg {}us max {}us, wait avg {}us max {}us, present avg {}us max {}us, interval avg {}us max {}us\n",
            .{
                report_every,
                self.acquire_ns / report_every / std.time.ns_per_us,
                self.acquire_max_ns / std.time.ns_per_us,
                self.wait_ns / report_every / std.time.ns_per_us,
                self.wait_max_ns / std.time.ns_per_us,
                self.present_ns / report_every / std.time.ns_per_us,
                self.present_max_ns / std.time.ns_per_us,
                self.interval_ns / (report_every - 1) / std.time.ns_per_us,
                self.interval_max_ns / std.time.ns_per_us,
            },
        );

        self.acquire_ns = 0;
        self.acquire_max_ns = 0;
        self.wait_ns = 0;
        self.wait_max_ns = 0;
        self.present_ns = 0;
        self.present_max_ns = 0;
        self.interval_ns = 0;
        self.interval_max_ns = 0;
    }

    fn recordPresent(self: *Trace, ns: u64) void {
        if (!self.enabled) return;
        accumulate(&self.present_ns, &self.present_max_ns, ns);
    }
};

fn accumulate(total: *u64, max: *u64, ns: u64) void {
    total.* += ns;
    if (ns > max.*) max.* = ns;
}

/// Nanoseconds on the monotonic clock. Zig 0.17 only offers clock reads through
/// `std.Io`, which the render callbacks have no handle on, and this one is not
/// even cheap everywhere: with the HPET clocksource the kernel has to be called
/// for the time, which is why the trace above is opt-in.
fn monotonicNs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// A swapchain and the images it holds. `Surface` swaps one of these out for
/// another when the window changes size.
const Swapchain = struct {
    handle: vk.SwapchainKHR,
    images: []vk.Image,
    /// Extent it was created with. The driver may clamp what we ask for, so this
    /// is not necessarily the size the view is composited at.
    extent: vk.Extent2D,
    /// Armed by every acquire of an image from this swapchain and waited on
    /// straight after: it signals when the image is free to write to again,
    /// which is what the presentation engine, rather than the GPU, decides.
    fence: vk.Fence,

    fn destroy(self: Swapchain, ctx: *Context) void {
        ctx.vkd.destroyFence(ctx.device, self.fence, null);
        ctx.vkd.destroySwapchainKHR(ctx.device, self.handle, null);
        ctx.allocator.free(self.images);
    }
};

/// A device-local image the engine renders a view into. The engine caches these
/// between frames, and asks us to create and destroy them through the
/// compositor callbacks.
pub const BackingStore = struct {
    ctx: *Context,
    image: vk.Image,
    memory: vk.DeviceMemory,
    extent: vk.Extent2D,
    format: vk.Format,

    pub fn create(ctx: *Context, extent: vk.Extent2D, format: vk.Format) !BackingStore {
        if (extent.width == 0 or extent.height == 0) return error.EmptyBackingStore;

        const image = try ctx.vkd.createImage(ctx.device, &.{
            .image_type = .@"2d",
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1" = true },
            .tiling = .optimal,
            // The engine wraps this as a Skia render target (color attachment)
            // and we read it back with a blit, so it needs both usages.
            .usage = .{
                .color_attachment = true,
                .transfer_src = true,
                .transfer_dst = true,
                .sampled = true,
            },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer ctx.vkd.destroyImage(ctx.device, image, null);

        const requirements = ctx.vkd.getImageMemoryRequirements(ctx.device, image);
        const memory_type = try ctx.findMemoryType(requirements.memory_type_bits, .{ .device_local = true });
        const memory = try ctx.vkd.allocateMemory(ctx.device, &.{
            .allocation_size = requirements.size,
            .memory_type_index = memory_type,
        }, null);
        errdefer ctx.vkd.freeMemory(ctx.device, memory, null);

        try ctx.vkd.bindImageMemory(ctx.device, image, memory, 0);

        return .{
            .ctx = ctx,
            .image = image,
            .memory = memory,
            .extent = extent,
            .format = format,
        };
    }

    pub fn destroy(self: *BackingStore) void {
        self.ctx.vkd.destroyImage(self.ctx.device, self.image, null);
        self.ctx.vkd.freeMemory(self.ctx.device, self.memory, null);
    }
};

/// A backing-store image handed back by the engine to composite onto a view.
pub const Layer = struct {
    image: vk.Image,
    extent: vk.Extent2D,
};

fn colorSubresourceRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

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
    /// Per-frame timing of the synchronization above, off unless asked for.
    trace: Trace,
    /// Commands that composite backing-store images onto the swapchain. The
    /// fence is armed by every submission and waited on before the buffer is
    /// reused, so a frame can be recorded while the previous one is still on
    /// the GPU.
    cmd_pool: vk.CommandPool,
    cmd: vk.CommandBuffer,
    cmd_fence: vk.Fence,
    cmd_fence_armed: bool = false,

    pub fn create(ctx: *Context, wl_display: *anyopaque, wl_surface: *anyopaque, width: u32, height: u32) !Surface {
        const surface = try ctx.vki.createWaylandSurfaceKHR(ctx.instance, &.{
            .display = @ptrCast(@alignCast(wl_display)),
            .surface = @ptrCast(@alignCast(wl_surface)),
        }, null);
        errdefer ctx.vki.destroySurfaceKHR(ctx.instance, surface, null);

        const size = vk.Extent2D{ .width = width, .height = height };
        const swapchain = try buildSwapchain(ctx, surface, size);
        errdefer swapchain.destroy(ctx);

        const cmd_pool = try ctx.vkd.createCommandPool(ctx.device, &.{
            .flags = .{ .reset_command_buffer = true },
            .queue_family_index = ctx.queue_family,
        }, null);
        errdefer ctx.vkd.destroyCommandPool(ctx.device, cmd_pool, null);

        var cmd: vk.CommandBuffer = undefined;
        try ctx.vkd.allocateCommandBuffers(ctx.device, &.{
            .command_pool = cmd_pool,
            .level = .primary,
            .command_buffer_count = 1,
        }, @ptrCast(&cmd));

        const cmd_fence = try ctx.vkd.createFence(ctx.device, &.{}, null);
        errdefer ctx.vkd.destroyFence(ctx.device, cmd_fence, null);

        return .{
            .ctx = ctx,
            .surface = surface,
            .swapchain = swapchain,
            .frame_size = size,
            .trace = Trace.init(ctx.options.trace),
            .cmd_pool = cmd_pool,
            .cmd = cmd,
            .cmd_fence = cmd_fence,
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

        // The old swapchain's images may still be in use: the engine
        // host-synced its own rendering before handing the last frame back, but
        // the present of that frame has not necessarily completed. Drain the
        // queue before tearing it down. This is once per resize rather than once
        // per frame, and it is the queue, not the whole device.
        try self.ctx.vkd.queueWaitIdle(self.ctx.queue);

        // The old swapchain goes first: a driver rejects a second one for the
        // same surface (`VK_ERROR_NATIVE_WINDOW_IN_USE_KHR`), which is what
        // passing it as `oldSwapchain` avoids, but that way a failed create
        // retires the old swapchain too, so it cannot be kept as a fallback
        // either.
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
        const present_mode = try choosePresentMode(ctx, surface);

        // Mailbox keeps `vkQueuePresentKHR` from blocking when an occluded
        // surface's buffers are not being released quickly. With several
        // windows, a FIFO stall on one surface otherwise blocks the single
        // raster thread (and therefore every view). Mailbox wants at least
        // three images so it always has one to replace and one to display.
        var image_count = if (present_mode == .mailbox_khr)
            @max(caps.min_image_count + 1, 3)
        else
            caps.min_image_count + 1;
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

        // Created unsignaled: it is armed by each acquire and reset after the
        // wait that follows it.
        const fence = try ctx.vkd.createFence(ctx.device, &.{}, null);
        errdefer ctx.vkd.destroyFence(ctx.device, fence, null);

        return .{
            .handle = swapchain,
            .images = images,
            .extent = extent,
            .fence = fence,
        };
    }

    pub fn destroy(self: *Surface) void {
        // Serialize with the raster thread: another view may still be
        // presenting when a view is removed. The engine has released this
        // surface, but the queue is shared.
        self.ctx.render_mutex.lockUncancelable(self.ctx.io);
        defer self.ctx.render_mutex.unlock(self.ctx.io);

        // The one place a device-wide wait is the right tool: once, at teardown,
        // with the engine already shut down.
        self.ctx.vkd.deviceWaitIdle(self.ctx.device) catch {};
        self.ctx.vkd.destroyFence(self.ctx.device, self.cmd_fence, null);
        self.ctx.vkd.destroyCommandPool(self.ctx.device, self.cmd_pool, null);
        if (self.swapchain) |swapchain| swapchain.destroy(self.ctx);
        self.ctx.vki.destroySurfaceKHR(self.ctx.instance, self.surface, null);
    }

    /// Acquire an image to composite a `width`×`height` view onto. The
    /// swapchain is rebuilt first when that size changed, or when a previous
    /// frame found it stale.
    ///
    /// This, `presentLayers` and `present` run on the engine's render thread,
    /// one frame at a time, so none of this state needs to be locked against
    /// the event loop: the loop only sends window metrics, it never touches the
    /// swapchain.
    pub fn acquire(self: *Surface, width: u32, height: u32) !vk.Image {
        const size = vk.Extent2D{ .width = width, .height = height };
        const frame_start = self.trace.now();

        var retried = false;
        while (true) {
            try self.resize(size);
            const swapchain = self.swapchain orelse return error.NoSwapchain;

            // Wait for this one image to be free to write to, rather than for
            // the whole device: the engine host-synced its own rendering before
            // handing the last frame back, so the presentation engine releasing
            // the image is the only thing left to synchronize on.
            const acquire_start = self.trace.now();
            const acquired = self.ctx.vkd.acquireNextImageKHR(
                self.ctx.device,
                swapchain.handle,
                std.math.maxInt(u64),
                .null,
                swapchain.fence,
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
            const acquire_ns = self.trace.since(acquire_start);
            // A fence left signaled cannot be passed to the next acquire, so
            // giving up past this point means giving up the swapchain with it.
            errdefer self.stale = true;
            const wait_start = self.trace.now();
            _ = try self.ctx.vkd.waitForFences(self.ctx.device, &.{swapchain.fence}, .true, std.math.maxInt(u64));
            try self.ctx.vkd.resetFences(self.ctx.device, &.{swapchain.fence});
            const wait_ns = self.trace.since(wait_start);

            // Usable for this frame, but not for the next one.
            if (acquired.result == .suboptimal_khr) self.stale = true;
            self.trace.record(acquire_ns, wait_ns, frame_start);
            return swapchain.images[acquired.image_index];
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
        const present_start = self.trace.now();
        const presented = self.ctx.vkd.queuePresentKHR(self.ctx.queue, &present_info) catch |err| switch (err) {
            // The frame was not shown. The image belongs to a swapchain that is
            // about to be rebuilt, so there is nothing left to present.
            error.OutOfDateKHR => {
                self.stale = true;
                return err;
            },
            else => return err,
        };
        self.trace.recordPresent(self.trace.since(present_start));

        if (presented == .suboptimal_khr) self.stale = true;
    }

    /// Prepare the command buffer for a new frame. The previous submission is
    /// waited on first, because its commands still own the buffer.
    fn beginCommands(self: *Surface) !vk.CommandBuffer {
        if (self.cmd_fence_armed) {
            _ = try self.ctx.vkd.waitForFences(self.ctx.device, &.{self.cmd_fence}, .true, std.math.maxInt(u64));
            try self.ctx.vkd.resetFences(self.ctx.device, &.{self.cmd_fence});
            self.cmd_fence_armed = false;
        }
        try self.ctx.vkd.resetCommandBuffer(self.cmd, .{});
        try self.ctx.vkd.beginCommandBuffer(self.cmd, &.{
            .flags = .{ .one_time_submit = true },
        });
        return self.cmd;
    }

    fn imageBarrier(
        self: *Surface,
        cmd: vk.CommandBuffer,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
        src_stage: vk.PipelineStageFlags,
        dst_stage: vk.PipelineStageFlags,
        src_access: vk.AccessFlags,
        dst_access: vk.AccessFlags,
    ) void {
        self.ctx.vkd.cmdPipelineBarrier(cmd, src_stage, dst_stage, .{}, null, null, &.{.{
            .src_access_mask = src_access,
            .dst_access_mask = dst_access,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = colorSubresourceRange(),
        }});
    }

    /// Composite the engine's backing-store images onto the swapchain and
    /// present them. The engine host-syncs its own rendering before calling
    /// this, so the only synchronization this needs is the layout transitions
    /// from the engine's color-attachment writes to our transfer reads.
    pub fn presentLayers(self: *Surface, width: u32, height: u32, layers: []const Layer) !void {
        // One queue is shared by every view, and surface teardown on the main
        // thread waits on that queue. Keep the whole acquire/composite/present
        // sequence atomic with respect to it.
        self.ctx.render_mutex.lockUncancelable(self.ctx.io);
        defer self.ctx.render_mutex.unlock(self.ctx.io);

        const image = try self.acquire(width, height);
        const swapchain = self.swapchain orelse return error.NoSwapchain;

        const cmd = try self.beginCommands();
        errdefer self.ctx.vkd.resetCommandBuffer(cmd, .{}) catch {};

        // The acquired image has undefined contents, and the backing stores may
        // not cover all of it, so clear it before compositing.
        self.imageBarrier(
            cmd,
            image,
            .undefined,
            .transfer_dst_optimal,
            .{ .top_of_pipe = true },
            .{ .transfer = true },
            .{},
            .{ .transfer_write = true },
        );
        const clear = vk.ClearColorValue{ .float_32 = .{ 0.0, 0.0, 0.0, 1.0 } };
        self.ctx.vkd.cmdClearColorImage(cmd, image, .transfer_dst_optimal, &clear, &.{colorSubresourceRange()});

        for (layers) |layer| {
            if (layer.extent.width == 0 or layer.extent.height == 0) continue;

            self.imageBarrier(
                cmd,
                layer.image,
                .color_attachment_optimal,
                .transfer_src_optimal,
                .{ .color_attachment_output = true },
                .{ .transfer = true },
                .{ .color_attachment_write = true },
                .{ .transfer_read = true },
            );

            // The engine has already applied the layer's offset and transform
            // while rendering, so the backing-store image is drawn at the
            // origin. It is normally exactly the size of the view.
            const dst_width = @min(layer.extent.width, swapchain.extent.width);
            const dst_height = @min(layer.extent.height, swapchain.extent.height);
            const blit = vk.ImageBlit{
                .src_subresource = .{
                    .aspect_mask = .{ .color = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .src_offsets = .{
                    .{ .x = 0, .y = 0, .z = 0 },
                    .{ .x = @intCast(layer.extent.width), .y = @intCast(layer.extent.height), .z = 1 },
                },
                .dst_subresource = .{
                    .aspect_mask = .{ .color = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .dst_offsets = .{
                    .{ .x = 0, .y = 0, .z = 0 },
                    .{ .x = @intCast(dst_width), .y = @intCast(dst_height), .z = 1 },
                },
            };
            self.ctx.vkd.cmdBlitImage(
                cmd,
                layer.image,
                .transfer_src_optimal,
                image,
                .transfer_dst_optimal,
                &.{blit},
                .linear,
            );

            // Leave the image ready for the engine to render into next frame.
            self.imageBarrier(
                cmd,
                layer.image,
                .transfer_src_optimal,
                .color_attachment_optimal,
                .{ .transfer = true },
                .{ .color_attachment_output = true },
                .{ .transfer_read = true },
                .{ .color_attachment_read = true, .color_attachment_write = true },
            );
        }

        self.imageBarrier(
            cmd,
            image,
            .transfer_dst_optimal,
            .present_src_khr,
            .{ .transfer = true },
            .{ .bottom_of_pipe = true },
            .{ .transfer_write = true },
            .{},
        );

        try self.ctx.vkd.endCommandBuffer(cmd);

        const commands = [_]vk.CommandBuffer{cmd};
        try self.ctx.vkd.queueSubmit(self.ctx.queue, &.{.{
            .command_buffer_count = 1,
            .p_command_buffers = &commands,
        }}, self.cmd_fence);
        self.cmd_fence_armed = true;

        try self.present(image);
    }

    /// Pick mailbox when the surface supports it. It decouples presentation
    /// from the compositor's buffer release, which matters once there is more
    /// than one window: a FIFO present that blocks holds up the raster thread
    /// and therefore every view.
    fn choosePresentMode(ctx: *Context, surface: vk.SurfaceKHR) !vk.PresentModeKHR {
        const modes = try ctx.vki.getPhysicalDeviceSurfacePresentModesAllocKHR(ctx.pdev, surface, ctx.allocator);
        defer ctx.allocator.free(modes);

        for (modes) |mode| {
            if (mode == .mailbox_khr) return .mailbox_khr;
        }
        return .fifo_khr;
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
