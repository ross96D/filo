const std = @import("std");

const zio = @import("zio");
const ev = zio.ev;

const c = @import("flutter");
const vk = @import("vulkan");
const wayland = @import("wayland");
const wl = wayland.client.wl;

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
const window_manager = @import("flutter/window_manager.zig");
const mouse_cursor = @import("flutter/mouse_cursor.zig");

/// One native window and the Flutter view rendered into it.
const View = struct {
    id: engine.ViewId,
    win: *window.Window,
    surface: vulkan.Surface,
    /// The engine has confirmed that the view exists.
    added: bool = false,
    /// A close was requested while the engine was still adding the view.
    close_requested: bool = false,
    /// RemoveView has been started; the surface must stay alive until it
    /// reports success.
    removing: bool = false,
    /// RemoveView was rejected synchronously (invalid or unknown id); do not
    /// retry it every frame.
    remove_failed: bool = false,
};

/// The one struct the callbacks reach into: it is the engine's `user_data`
/// (the compositor callbacks and the platform message callback reach it), the
/// loop sources' context (the display and task eventfd callbacks reach the
/// globals in `ctx` plus the view registry), and the owner of every window.
const App = struct {
    ctx: context.Context,
    vk: *vulkan.Context,
    views: std.ArrayListUnmanaged(*View) = .empty,
    views_by_id: std.AutoHashMapUnmanaged(engine.ViewId, *View) = .empty,
    views_by_surface: std.AutoHashMapUnmanaged(*wl.Surface, *View) = .empty,
    /// The one frame clock: it owns a callback per surface and fires vsync for
    /// the whole engine. Null only before the engine and loop exist.
    frame_clock: ?*frame_clock.FrameClock = null,
    next_view_id: engine.ViewId = 1,
    /// Whether `ctx` has been filled in. `deinitViews` also runs after a failed
    /// engine initialization, before the context exists.
    ctx_ready: bool = false,
    /// Read by the vsync callback on the engine's raster thread, so it is
    /// written before the engine can ask for a frame and cleared under the same
    /// atomic when it is torn down.
    engine: std.atomic.Value(?*engine.Engine) = std.atomic.Value(?*engine.Engine).init(null),
    channels: platform_channel.Registry,
    compositor: c.FlutterCompositor = undefined,

    display_probe: ev.PipePoll = .init(-1, .read),
    platform_probe: ev.PipePoll = .init(-1, .read),
    err: ?anyerror = null,

    fn viewForId(self: *App, id: engine.ViewId) ?*View {
        return self.views_by_id.get(id);
    }

    fn reserveViewId(self: *App) engine.ViewId {
        var id = self.next_view_id;
        while (self.views_by_id.contains(id)) id += 1;
        self.next_view_id = id + 1;
        return id;
    }

    /// Create the surface and bookkeeping for a window, and register its Wayland
    /// surface with the shared frame clock. The window is owned by the view on
    /// success and by the caller on failure.
    fn adoptView(self: *App, id: engine.ViewId, win: *window.Window) !*View {
        var surface = try vulkan.Surface.create(
            self.vk,
            @ptrCast(self.ctx.conn.display),
            @ptrCast(win.surface),
            win.width,
            win.height,
        );
        errdefer surface.destroy();

        const view = try self.ctx.allocator.create(View);
        errdefer self.ctx.allocator.destroy(view);
        view.* = .{
            .id = id,
            .win = win,
            .surface = surface,
        };

        try self.frame_clock.?.addSurface(win.surface);
        errdefer self.frame_clock.?.removeSurface(win.surface);

        try self.views.append(self.ctx.allocator, view);
        errdefer _ = self.views.pop();
        try self.views_by_id.put(self.ctx.allocator, id, view);
        errdefer _ = self.views_by_id.remove(id);
        try self.views_by_surface.put(self.ctx.allocator, win.surface, view);
        errdefer _ = self.views_by_surface.remove(win.surface);

        return view;
    }

    /// Open a new Wayland window and register a view for it. The view is not
    /// visible to the engine until `beginAddView` completes.
    fn createView(self: *App, width: u32, height: u32) !*View {
        const id = self.reserveViewId();
        const win = try self.ctx.conn.createWindow();
        var owned = true;
        errdefer {
            if (owned) win.destroy(self.ctx.allocator);
        }

        // The initial configure normally carries the real size; these are the
        // fallback when the compositor leaves the choice to us.
        if (width > 0) win.width = width;
        if (height > 0) win.height = height;
        try self.ctx.conn.waitReady(win);

        const view = try self.adoptView(id, win);
        owned = false;
        return view;
    }

    /// Create a view and tell the engine about it. Resources exist before the
    /// asynchronous add starts, so a frame presented for it can always find its
    /// surface.
    fn spawnView(self: *App, width: u32, height: u32) !*View {
        const view = try self.createView(width, height);
        self.beginAddView(view) catch |err| {
            self.destroyView(view);
            return err;
        };
        return view;
    }

    fn beginAddView(self: *App, view: *View) !void {
        const op = try self.ctx.allocator.create(ViewOp);
        op.* = .{ .app = self, .view = view, .kind = .add };
        self.ctx.eng.addView(
            view.id,
            view.win.width,
            view.win.height,
            view.win.pixel_ratio,
            op,
            addViewCallback,
        ) catch |err| {
            self.ctx.allocator.destroy(op);
            return err;
        };
    }

    fn beginRemoveView(self: *App, view: *View) !void {
        const op = try self.ctx.allocator.create(ViewOp);
        op.* = .{ .app = self, .view = view, .kind = .remove };
        self.ctx.eng.removeView(view.id, op, removeViewCallback) catch |err| {
            self.ctx.allocator.destroy(op);
            return err;
        };
    }

    /// Destroy a view and everything it owns. Call only after the engine has
    /// released the view (or while tearing down an engine that never had it).
    fn destroyView(self: *App, view: *View) void {
        _ = self.views_by_id.remove(view.id);
        _ = self.views_by_surface.remove(view.win.surface);
        for (self.views.items, 0..) |item, index| {
            if (item == view) {
                _ = self.views.swapRemove(index);
                break;
            }
        }
        if (self.frame_clock) |clock| clock.removeSurface(view.win.surface);

        view.surface.destroy();
        view.win.destroy(self.ctx.allocator);
        self.ctx.allocator.destroy(view);
    }

    fn deinitViews(self: *App) void {
        if (!self.ctx_ready) return;

        // Drop the frame clock's callbacks before the surfaces they watch.
        if (self.frame_clock) |clock| clock.deinit();

        for (self.views.items) |view| {
            view.surface.destroy();
            view.win.destroy(self.ctx.allocator);
            self.ctx.allocator.destroy(view);
        }
        self.views.clearRetainingCapacity();
        self.views.deinit(self.ctx.allocator);
        self.views_by_id.deinit(self.ctx.allocator);
        self.views_by_surface.deinit(self.ctx.allocator);
    }

    /// Queue a view-operation result for the Wayland/Vulkan thread. The engine
    /// callbacks run on its own thread; nothing here may touch a surface.
    fn postViewOp(self: *App, op: *ViewOp) void {
        const eng = self.engine.load(.acquire) orelse {
            // The engine is shutting down; the resources are released by
            // `deinitViews` instead.
            self.ctx.allocator.destroy(op);
            return;
        };
        eng.postMainTask(runViewOp, op);
    }

    /// The engine has finished rendering a view into backing-store images. Blit
    /// them onto that view's swapchain and present it.
    fn presentView(self: *App, info: *const c.FlutterPresentViewInfo) bool {
        const view = self.views_by_id.get(info.view_id) orelse return true;

        // One layer per Flutter view, plus platform views if the app uses them.
        // The engine does not put a hard limit on the count, but a frame with
        // more layers than this is not something this embedder can composite.
        var layers: [16]vulkan.Layer = undefined;
        var count: usize = 0;
        var width: u32 = 0;
        var height: u32 = 0;

        for (info.layers[0..info.layers_count]) |layer_ptr| {
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
        // the last size this view drew at; before any frame there is nothing to
        // present at all.
        if (width == 0 or height == 0) {
            width = view.surface.frame_size.width;
            height = view.surface.frame_size.height;
        }
        if (width == 0 or height == 0) return true;

        view.surface.presentLayers(width, height, layers[0..count]) catch |err| {
            std.debug.print("fembed: compositor present failed for view {}: {}\n", .{ info.view_id, err });
            return false;
        };
        return true;
    }
};

const ViewOpKind = enum { add, remove };

/// Baton for one asynchronous AddView/RemoveView operation.
const ViewOp = struct {
    app: *App,
    view: *View,
    kind: ViewOpKind,
    ok: bool = false,
};

fn addViewCallback(result: [*c]const c.FlutterAddViewResult) callconv(.c) void {
    if (result == null or result.*.user_data == null) return;
    const op: *ViewOp = @ptrCast(@alignCast(result.*.user_data.?));
    op.ok = result.*.added;
    op.app.postViewOp(op);
}

fn removeViewCallback(result: [*c]const c.FlutterRemoveViewResult) callconv(.c) void {
    if (result == null or result.*.user_data == null) return;
    const op: *ViewOp = @ptrCast(@alignCast(result.*.user_data.?));
    op.ok = result.*.removed;
    op.app.postViewOp(op);
}

fn runViewOp(user_data: ?*anyopaque) void {
    const op: *ViewOp = @ptrCast(@alignCast(user_data.?));
    const app = op.app;
    const view = op.view;

    switch (op.kind) {
        .add => if (op.ok) {
            view.added = true;
            std.debug.print("fembed: view {} added\n", .{view.id});
            if (view.close_requested) view.win.closing = true;
        } else {
            std.debug.print("fembed: view {} could not be added\n", .{view.id});
            app.destroyView(view);
        },
        .remove => if (op.ok) {
            std.debug.print("fembed: view {} removed\n", .{view.id});
            app.destroyView(view);
        } else {
            std.debug.print("fembed: view {} could not be removed\n", .{view.id});
            view.removing = false;
            view.remove_failed = true;
        },
    }

    app.ctx.allocator.destroy(op);
}

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
    const app: *App = @ptrCast(@alignCast(user_data.?));

    const size = config.*.size;
    const extent = vk.Extent2D{
        .width = @intFromFloat(@max(size.width, 1.0)),
        .height = @intFromFloat(@max(size.height, 1.0)),
    };

    // BGRA is the format the Linux embedder uses elsewhere, and it is what the
    // swapchain prefers; the compositor blits between them when they differ.
    var store = vulkan.BackingStore.create(app.vk, extent, .b8g8r8a8_unorm) catch |err| {
        std.debug.print("fembed: could not create backing store: {}\n", .{err});
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
    const app: *App = @ptrCast(@alignCast(info.*.user_data.?));
    return app.presentView(info);
}

fn getInstanceProcAddr(
    user_data: ?*anyopaque,
    instance: c.FlutterVulkanInstanceHandle,
    name: [*c]const u8,
) callconv(.c) ?*anyopaque {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const vk_instance: vk.Instance = @ptrCast(instance);
    const name_z: [*:0]const u8 = @ptrCast(name);
    const fnptr = app.vk.vkb.dispatch.vkGetInstanceProcAddr.?(vk_instance, name_z);
    const p = fnptr orelse return null;
    return @ptrCast(@constCast(p));
}

/// `FlutterVulkanRendererConfig` requires these callbacks to be non-null, but
/// the compositor path never calls them: the engine renders into backing stores
/// and `presentView` composites those.
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

fn rendererConfig(vk_ctx: *vulkan.Context) c.FlutterRendererConfig {
    var config: c.FlutterRendererConfig = undefined;
    config.type = c.kVulkan;
    config.unnamed_0.vulkan = .{
        .struct_size = @sizeOf(c.FlutterVulkanRendererConfig),
        .version = vk.API_VERSION_1_3.toU32(),
        .instance = @ptrCast(vk_ctx.instance),
        .physical_device = @ptrCast(vk_ctx.pdev),
        .device = @ptrCast(vk_ctx.device),
        .queue_family_index = vk_ctx.queue_family,
        .queue = @ptrCast(vk_ctx.queue),
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

/// Resolve the view a Wayland surface belongs to. `Input` uses this for keyboard
/// focus and pointer routing.
fn viewForSurface(user_data: ?*anyopaque, surface: *wl.Surface) ?engine.ViewId {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const view = app.views_by_surface.get(surface) orelse return null;
    return view.id;
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

/// Invoked by the engine on the platform thread when the framework wants a
/// native view focused, for example after a focus traversal or an explicit
/// `FocusScope` request. Wayland does not let a client take keyboard focus, so
/// there is nothing to do beyond recording that the request happened; the
/// compositor decides when the surface actually receives focus.
fn viewFocusChangeRequestCallback(
    request: [*c]const c.FlutterViewFocusChangeRequest,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = user_data;
    if (request == null) return;

    const state: c_int = @intCast(request.*.state);
    const direction: c_int = @intCast(request.*.direction);
    std.debug.print("fembed: view {} focus request: {s} ({s})\n", .{
        request.*.view_id,
        switch (state) {
            c.kFocused => "focused",
            c.kUnfocused => "unfocused",
            else => "unknown",
        },
        switch (direction) {
            c.kForward => "forward",
            c.kBackward => "backward",
            c.kUndefined => "none",
            else => "unknown",
        },
    });
}

const CreateWindowRequest = struct {
    app: *App,
    width: u32,
    height: u32,
};

fn onCreateWindow(user_data: ?*anyopaque, width: u32, height: u32) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const req = std.heap.c_allocator.create(CreateWindowRequest) catch return;
    req.* = .{ .app = app, .width = width, .height = height };
    app.ctx.eng.postMainTask(runCreateWindow, req);
}

fn runCreateWindow(user_data: ?*anyopaque) void {
    const req: *CreateWindowRequest = @ptrCast(@alignCast(user_data.?));
    defer std.heap.c_allocator.destroy(req);
    _ = req.app.spawnView(req.width, req.height) catch |err| {
        std.debug.print("fembed: could not create window: {}\n", .{err});
    };
}

const CloseWindowRequest = struct {
    app: *App,
    view_id: engine.ViewId,
};

fn onCloseWindow(user_data: ?*anyopaque, view_id: engine.ViewId) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const req = std.heap.c_allocator.create(CloseWindowRequest) catch return;
    req.* = .{ .app = app, .view_id = view_id };
    app.ctx.eng.postMainTask(runCloseWindow, req);
}

fn runCloseWindow(user_data: ?*anyopaque) void {
    const req: *CloseWindowRequest = @ptrCast(@alignCast(user_data.?));
    defer std.heap.c_allocator.destroy(req);

    const view = req.app.viewForId(req.view_id) orelse return;
    if (view.id == 0) {
        // The implicit view cannot be removed; closing its window exits.
        req.app.ctx.loop.stop();
        return;
    }
    if (!view.added) {
        view.close_requested = true;
        return;
    }
    view.win.closing = true;
}

const CursorRequest = struct {
    conn: *connection.Connection,
    cursor: mouse_cursor.Cursor,
};

fn onSetCursor(user_data: ?*anyopaque, cursor: mouse_cursor.Cursor) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const req = std.heap.c_allocator.create(CursorRequest) catch return;
    req.* = .{ .conn = app.ctx.conn, .cursor = cursor };
    app.ctx.eng.postMainTask(runSetCursor, req);
}

fn runSetCursor(user_data: ?*anyopaque) void {
    const req: *CursorRequest = @ptrCast(@alignCast(user_data.?));
    defer std.heap.c_allocator.destroy(req);
    req.conn.setCursor(req.cursor);
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

/// Work the loop owes after any wake: resizes the compositor asked for, close
/// requests, a tick the engine is waiting on, and the requests those queued on
/// the connection.
fn afterDispatch(self: *App, loop: *ev.Loop) void {
    if (self.views.items.len == 0) {
        loop.stop();
        return;
    }

    for (self.views.items) |view| {
        if (view.win.closing) {
            if (view.id == 0) {
                loop.stop();
                return;
            }
            // The engine is still adding this view; remove it once the add
            // callback says it exists.
            if (!view.added) {
                view.close_requested = true;
                continue;
            }
            if (!view.removing and !view.remove_failed) {
                view.removing = true;
                self.beginRemoveView(view) catch |err| {
                    std.debug.print("fembed: could not remove view {}: {}\n", .{ view.id, err });
                    view.removing = false;
                    view.remove_failed = true;
                };
            }
            continue;
        }
        if (view.added) view.win.applyResize(self.ctx.eng, view.id);
    }

    self.ctx.eng.frame_period_ns = self.ctx.conn.frame_period_ns;
    if (self.frame_clock) |clock| {
        clock.setPeriod(self.ctx.conn.frame_period_ns);
        clock.service();
    }
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

    const first_win = try conn.createWindow();
    var first_win_owned = true;
    defer {
        if (first_win_owned) first_win.destroy(allocator);
    }

    try conn.waitReady(first_win);

    // The one loop in the program. Everything below registers a descriptor or
    // a timer with it and does its work from a callback.
    var loop: zio.ev.Loop = undefined;
    try loop.init(.{ .allocator = allocator });
    defer loop.deinit();

    var vk_ctx = try vulkan.Context.init(allocator, init.io, .{
        .validation = init.environ_map.get("FEMBED_VULKAN_VALIDATION") != null,
        .trace = init.environ_map.get("FEMBED_TRACE") != null,
    });
    defer vk_ctx.deinit();

    var app = App{
        .ctx = undefined,
        .vk = &vk_ctx,
        .channels = platform_channel.Registry.init(allocator),
    };
    defer app.channels.deinit();
    defer app.deinitViews();

    const renderer = rendererConfig(&vk_ctx);

    // Impeller's Vulkan backend cannot render into compositor backing stores.
    // FORCE_IMPELLER still turns it on, which is expected to fail: this embedder
    // has no direct-to-swapchain path any more.
    app.compositor = .{
        .struct_size = @sizeOf(c.FlutterCompositor),
        .user_data = &app,
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
        viewFocusChangeRequestCallback,
    );
    defer eng.deinit(allocator);
    app.channels.eng = eng;

    // The globals are only complete once the engine exists.
    app.ctx = .{ .allocator = allocator, .loop = &loop, .conn = conn, .eng = eng };
    app.frame_clock = try frame_clock.FrameClock.init(&app.ctx, conn.frame_period_ns);
    app.ctx_ready = true;

    const first_view = try app.adoptView(0, first_win);
    first_view.added = true;
    first_win_owned = false;

    var ti = text_input.TextInput.init(allocator, eng);
    defer ti.deinit();
    app.channels.text_input = &ti;

    var inp = try input.Input.init(eng, &ti);
    defer inp.deinit();
    inp.setViewResolver(&app, viewForSurface);
    try conn.bindSeat(&app.ctx, &inp);

    var ph = platform_handler.PlatformHandler.init(allocator, eng, conn.clipboard.?, &loop);
    defer ph.deinit();
    ph.attach();
    app.channels.platform = &ph;

    var wm = window_manager.WindowManager{
        .eng = eng,
        .user_data = &app,
        .create = onCreateWindow,
        .close = onCloseWindow,
    };
    app.channels.windows = &wm;

    var mc = mouse_cursor.MouseCursor{
        .eng = eng,
        .user_data = &app,
        .set = onSetCursor,
    };
    app.channels.mouse_cursor = &mc;

    eng.sendWindowMetricsForView(0, first_view.win.width, first_view.win.height, first_view.win.pixel_ratio);
    // Without this the engine has no display at all and falls back for the
    // refresh rate it derives its frame budget from.
    if (conn.refresh_mhz != 0) {
        eng.notifyDisplayStartup(.{
            .refresh_rate = @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
            .width = conn.display_width,
            .height = conn.display_height,
            .pixel_ratio = first_view.win.pixel_ratio,
        });
        std.debug.print("fembed: display {}x{} at {d:.3} Hz\n", .{
            conn.display_width,
            conn.display_height,
            @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
        });
    }

    // A way to exercise multi-view rendering without clicking anything.
    if (init.environ_map.get("FEMBED_EXTRA_WINDOWS")) |value| {
        const count = std.fmt.parseInt(usize, value, 10) catch 2;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            _ = app.spawnView(800, 600) catch |err| {
                std.debug.print("fembed: could not open extra window: {}\n", .{err});
                break;
            };
        }
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
