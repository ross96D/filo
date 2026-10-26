//! The embedder's state: the `App`, its views, the windowing bridge and the
//! event-loop callbacks. `runtime.zig` owns the lifecycle; `lib.zig` is the
//! public module root.

const std = @import("std");

const zio = @import("zio");
const ev = zio.ev;

const c = @import("flutter");
const vk = @import("vulkan");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const xdg = wayland.client.xdg;

const engine = @import("engine.zig");
const scale = @import("scale.zig");
const connection = @import("wayland/connection.zig");
const window = @import("wayland/window.zig");
const frame_clock = @import("wayland/frame_clock.zig");
const context = @import("context.zig");
const vulkan = @import("vulkan.zig");
const platform_channel = @import("flutter/platform_channel.zig");
const mouse_cursor = @import("flutter/mouse_cursor.zig");
const windowing = @import("windowing.zig");
const max_content_size = @import("wayland/window.zig").max_content_size;

/// One native window and the Flutter view rendered into it.
pub const View = struct {
    id: engine.ViewId,
    win: *window.Window,
    surface: vulkan.Surface,
    /// Where this view is in the engine's AddView/RemoveView lifecycle.
    engine_state: EngineState = .adding,
    /// A close request arrived before AddView completed; apply it after add.
    close_after_add: bool = false,
    /// `filo_window_destroy` asked for this view to go away.
    destroy_requested: bool = false,
    /// Backend callbacks registered through `filo_window_observe`. Null means
    /// no controller is observing this view.
    callbacks: windowing.WindowCallbacks = windowing.empty_callbacks,
    /// The title the bridge last set, kept so the handle/getter can return it.
    /// NUL-terminated.
    title: [256]u8 = @splat(0),
    /// The extent of the last frame observed for this view, packed as
    /// width << 32 | height. It starts at the native window size at adoption
    /// and is updated from presented frames, never from a compositor
    /// configure: it is the baseline for detecting a content-size change.
    /// `presentView` runs on the raster thread, so it cannot read the
    /// main-thread window fields directly.
    content_size: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// A content resize has been requested at least once. The first frame is
    /// always applied, even when it happens to match the placeholder size, so
    /// a non-resizable window gets pinned and a resizable one finishes its
    /// initial auto-size.
    content_frame_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A content resize is queued or waiting for the popup configure.
    content_resize_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A buffer-scale change is in flight. Content-size tracking is paused until
    /// a frame at the new scale has been presented, so an in-flight frame at
    /// the old scale cannot be mistaken for a content-size change.
    scale_transition: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    /// The states the engine's AddView/RemoveView lifecycle can be in.
    pub const EngineState = enum {
        /// AddView has not reported success yet.
        adding,
        /// The engine owns a view with this id.
        added,
        /// AddView refused the view.
        add_failed,
        /// RemoveView is in flight.
        removing,
        /// RemoveView was rejected; do not retry.
        remove_failed,
    };

    fn packedSize(width: u32, height: u32) u64 {
        return (@as(u64, width) << 32) | @as(u64, height);
    }

    fn updateContentSize(self: *View, width: u32, height: u32) void {
        self.content_size.store(packedSize(width, height), .release);
    }

    fn contentWidth(self: *const View) u32 {
        return @intCast(self.content_size.load(.acquire) >> 32);
    }

    fn contentHeight(self: *const View) u32 {
        return @truncate(self.content_size.load(.acquire));
    }

    /// Store the title the bridge exposes to Dart, truncated to the fixed buffer
    /// that backs `FiloWindowHandle.title` and the future `get_title`.
    fn setViewTitleZ(self: *View, title: ?[*:0]const u8) void {
        const src = if (title) |t| std.mem.span(t) else "";
        const n = @min(src.len, self.title.len - 1);
        @memcpy(self.title[0..n], src[0..n]);
        self.title[n] = 0;
    }

    fn viewTitleZ(self: *View) [*:0]const u8 {
        return @ptrCast(&self.title);
    }

    /// Drain the events the Wayland listeners recorded and hand them to the
    /// registered callbacks. Runs on the main (UI) thread.
    fn emitWindowEvents(self: *View, eng: *engine.Engine) void {
        // Do not update `content_size` here. It is the last frame extent, not
        // the native size; a compositor configure must not reset the baseline
        // the raster thread compares content changes against.
        if (self.win.scale_dirty) {
            // The raster thread applies this with the first compatible frame;
            // see `vulkan.Surface.applyPendingBufferScale`. Content tracking is
            // paused until that frame arrives, so the old physical extent is
            // not mistaken for a content change.
            self.scale_transition.store(self.win.bufferScale(), .release);
            self.surface.requestBufferScale(self.win.bufferScale());
        }
        if (self.win.resized or self.win.scale_dirty) {
            const resized = self.win.resized;
            // applyResize sends physical metrics and clears both flags.
            self.win.applyResize(eng, self.id);
            if (resized) {
                // The controller-facing size is logical/surface-local.
                if (self.callbacks.on_configure) |on_configure| {
                    on_configure(@intCast(self.win.width), @intCast(self.win.height));
                }
            }
        }
        switch (self.win.role) {
            .toplevel => |*toplevel| {
                if (toplevel.state_dirty) {
                    toplevel.state_dirty = false;
                    if (self.callbacks) |callbacks| {
                        if (callbacks.on_state) |on_state| on_state(toplevel.toplevelState());
                    }
                }
                if (toplevel.capabilities_dirty) {
                    toplevel.capabilities_dirty = false;
                    if (self.callbacks.on_capabilities) |on_capabilities| {
                        on_capabilities(toplevel.wmCapabilities());
                    }
                }
            },
            .popup => |*popup| {
                if (popup.configure_seen) {
                    popup.configure_seen = false;
                    self.content_resize_pending.store(false, .release);
                }
                if (popup.offset_dirty) {
                    popup.offset_dirty = false;
                    if (self.callbacks.on_moved) |on_moved| {
                        const offset = popup.offsetFromParent();
                        on_moved(offset.x, offset.y);
                    }
                }
            },
            .layer => {},
        }
    }
};

/// The one struct the callbacks reach into: it is the engine's `user_data`
/// (the compositor callbacks and the platform message callback reach it), the
/// loop sources' context (the display and task eventfd callbacks reach the
/// globals in `ctx` plus the view registry), and the owner of every window.
pub const App = struct {
    ctx: context.Context,
    vk: *vulkan.Context,
    views: std.ArrayListUnmanaged(*View) = .empty,
    views_by_id: std.AutoHashMapUnmanaged(engine.ViewId, *View) = .empty,
    views_by_surface: std.AutoHashMapUnmanaged(*wl.Surface, *View) = .empty,
    /// The one frame clock: it owns a callback per surface and fires vsync for
    /// the whole engine. Null only before the engine and loop exist.
    frame_clock: ?*frame_clock.FrameClock = null,
    next_view_id: engine.ViewId = 1,
    /// Whether a windowing controller has adopted the implicit view (id 0).
    implicit_adopted: bool = false,
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
    /// `FILO_WINDOWING_SPIKE`: create and destroy one regular window from the
    /// event loop, to prove `AddView` completes synchronously on this thread.
    windowing_spike: bool = false,
    windowing_spike_done: bool = false,
    /// Whether any view has ever been registered. The loop stays alive with
    /// zero views until the first window is created; after that, zero views
    /// means the app is done.
    saw_view: bool = false,
    /// The loop sources are only registered once, by `runLoop`.
    loop_sources_added: bool = false,

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
    pub fn adoptView(self: *App, id: engine.ViewId, win: *window.Window) !*View {
        const transparent = switch (win.role) {
            .layer => true,
            .toplevel, .popup => false,
        };
        var surface = try vulkan.Surface.create(
            self.vk,
            @ptrCast(self.ctx.conn.display),
            @ptrCast(win.surface),
            win.physicalWidth(),
            win.physicalHeight(),
            transparent,
        );
        errdefer surface.destroy();
        surface.requestBufferScale(win.bufferScale());

        const view = try self.ctx.allocator.create(View);
        errdefer self.ctx.allocator.destroy(view);
        view.* = .{
            .id = id,
            .win = win,
            .surface = surface,
        };
        view.updateContentSize(win.physicalWidth(), win.physicalHeight());

        try self.frame_clock.?.addSurface(win.surface);
        errdefer self.frame_clock.?.removeSurface(win.surface);

        try self.views.append(self.ctx.allocator, view);
        errdefer _ = self.views.pop();
        try self.views_by_id.put(self.ctx.allocator, id, view);
        errdefer _ = self.views_by_id.remove(id);
        try self.views_by_surface.put(self.ctx.allocator, win.surface, view);
        errdefer _ = self.views_by_surface.remove(win.surface);

        self.saw_view = true;
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

    /// Create a toplevel from a windowing request and apply its properties.
    fn createToplevel(self: *App, req: *windowing.WindowRequest) !*View {
        const sized_to_content = req.sized_to_content != 0;
        // The first regular window adopts the implicit view. If the embedder
        // did not bootstrap a toplevel (or the implicit surface has another
        // role), create one lazily and never AddView it.
        if (req.preferred_view_id == 0 and !self.implicit_adopted) {
            if (self.viewForId(0)) |view| {
                // Only a toplevel can be adopted as the implicit toplevel. A
                // layer or popup implicit surface stays as it is.
                switch (view.win.role) {
                    .toplevel => return self.adoptToplevelView(view, req),
                    .popup, .layer => {},
                }
            } else {
                const initial_width = @max(1, @min(req.min_size.width, max_content_size));
                const initial_height = @max(1, @min(req.min_size.height, max_content_size));
                const width: u32 = if (req.size.width > 0)
                    @min(req.size.width, max_content_size)
                else if (sized_to_content)
                    initial_width
                else
                    800;
                const height: u32 = if (req.size.height > 0)
                    @min(req.size.height, max_content_size)
                else if (sized_to_content)
                    initial_height
                else
                    600;

                const win = try self.ctx.conn.createWindow();
                var owned = true;
                errdefer if (owned) win.destroy(self.ctx.allocator);
                if (width > 0) win.width = width;
                if (height > 0) win.height = height;
                try self.ctx.conn.waitReady(win);

                const view = try self.adoptView(0, win);
                owned = false;
                return self.adoptToplevelView(view, req);
            }
        }

        const initial_width = @max(1, @min(req.min_size.width, max_content_size));
        const initial_height = @max(1, @min(req.min_size.height, max_content_size));
        const width: u32 = if (req.size.width > 0)
            @min(req.size.width, max_content_size)
        else if (sized_to_content)
            initial_width
        else
            800;
        const height: u32 = if (req.size.height > 0)
            @min(req.size.height, max_content_size)
        else if (sized_to_content)
            initial_height
        else
            600;

        const view = try self.createView(width, height);
        errdefer self.destroyView(view);
        view.win.applyRequest(req);
        const toplevel = &view.win.role.toplevel;

        if (req.parent_view_id >= 0) {
            const parent = self.viewForId(req.parent_view_id) orelse return error.UnknownParent;
            switch (parent.win.role) {
                .toplevel => |*parent_toplevel| toplevel.setParent(parent_toplevel),
                .popup, .layer => toplevel.setParent(null),
            }
        }

        if (req.title) |title| toplevel.setTitle(title);
        view.setViewTitleZ(req.title);

        if (sized_to_content) {
            // Until the first frame arrives, only the requested constraints
            // apply. A non-resizable sized-to-content window is pinned to its
            // content size once that size is known.
            toplevel.setMinSize(req.min_size);
            toplevel.setMaxSize(req.max_size);
        } else if (req.resizable == 0) {
            const fixed = if (req.size.width > 0 and req.size.height > 0)
                windowing.Size{ .width = req.size.width, .height = req.size.height }
            else
                windowing.Size{ .width = view.win.width, .height = view.win.height };
            toplevel.setMinSize(fixed);
            toplevel.setMaxSize(fixed);
        } else {
            toplevel.setMinSize(req.min_size);
            toplevel.setMaxSize(req.max_size);
        }
        // The xdg_toplevel requests above are double-buffered.
        view.win.commit();

        // The initial state is returned in the handle; do not replay it as
        // events once the caller registers its callbacks.
        view.win.resized = false;
        toplevel.state_dirty = false;
        toplevel.capabilities_dirty = false;
        return view;
    }

    /// Finish adopting the implicit view as a toplevel. The view already exists
    /// in the engine, so it must never go through `AddView`.
    fn adoptToplevelView(self: *App, view: *View, req: *const windowing.WindowRequest) !*View {
        self.implicit_adopted = true;
        view.engine_state = .added;

        view.win.applyRequest(req);
        const toplevel = &view.win.role.toplevel;
        // The view may have survived a hot restart. Re-apply the first
        // content-sized frame so sizing state (pinning or the resizable
        // one-shot) is established again.
        view.content_frame_seen.store(false, .release);
        // Send the first metrics before any extra toplevel requests. The view
        // already has the compositor's configured size; a title/constraint
        // commit here can otherwise race the first frame.
        self.notifyAdoptedView(view);

        if (req.title) |title| {
            toplevel.setTitle(title);
            view.setViewTitleZ(req.title);
        }
        if (req.sized_to_content != 0) {
            // The content size is not known yet. Keep the requested bounds
            // until the first frame pins a non-resizable window to its content
            // size (see `runContentResize`).
            toplevel.setMinSize(req.min_size);
            toplevel.setMaxSize(req.max_size);
        } else if (req.resizable == 0) {
            const fixed = if (req.size.width > 0 and req.size.height > 0)
                windowing.Size{ .width = req.size.width, .height = req.size.height }
            else
                windowing.Size{ .width = view.win.width, .height = view.win.height };
            toplevel.setMinSize(fixed);
            toplevel.setMaxSize(fixed);
        } else {
            toplevel.setMinSize(req.min_size);
            toplevel.setMaxSize(req.max_size);
        }
        view.win.commit();

        view.win.resized = false;
        toplevel.state_dirty = false;
        toplevel.capabilities_dirty = false;
        return view;
    }

    /// Send the initial metrics for a view that was adopted instead of added.
    /// `AddView` normally carries these; the implicit view never gets one.
    ///
    /// This is queued rather than sent inline: the controller creates windows
    /// from inside a Dart callback, and `FlutterEngineSendWindowMetricsEvent`
    /// flushes the UI task runner. Re-entering it from there can wedge the
    /// engine's frame scheduling.
    fn notifyAdoptedView(self: *App, view: *View) void {
        const req = std.heap.c_allocator.create(AdoptViewRequest) catch return;
        req.* = .{ .app = self, .view = view };
        self.ctx.eng.postMainTask(runAdoptViewMetrics, req);
    }

    /// Create a popup from a windowing request and apply its initial position.
    fn createPopup(self: *App, req: *const windowing.WindowRequest) !*View {
        if (req.parent_view_id < 0) return error.InvalidParent;
        const parent = self.viewForId(req.parent_view_id) orelse return error.UnknownParent;

        var positioner = req.positioner;
        if (positioner.size.width == 0 or positioner.size.height == 0) positioner.size = req.size;
        if (positioner.size.width == 0 or positioner.size.height == 0) {
            positioner.size = .{ .width = 1, .height = 1 };
        }
        if (req.sized_to_content != 0) {
            // The positioner's size is the initial surface size. It has to
            // satisfy the engine's minimum constraint until the first frame
            // reports the content size.
            positioner.size.width = @max(positioner.size.width, @max(1, @min(req.min_size.width, 16_384)));
            positioner.size.height = @max(positioner.size.height, @max(1, @min(req.min_size.height, 16_384)));
        }

        const xdg_positioner = try makePositioner(self, positioner);
        defer xdg_positioner.destroy();

        const width: u32 = @min(positioner.size.width, 16_384);
        const height: u32 = @min(positioner.size.height, 16_384);

        const view = try self.createPopupView(parent, xdg_positioner, width, height);
        errdefer self.destroyView(view);
        view.win.applyRequest(req);

        view.win.role.popup.positioner = positioner;
        view.win.resized = false;
        view.win.role.popup.offset_dirty = false;
        return view;
    }

    /// Open a popup window attached to `parent` and register a view for it.
    fn createPopupView(
        self: *App,
        parent: *View,
        positioner: *xdg.Positioner,
        width: u32,
        height: u32,
    ) !*View {
        const id = self.reserveViewId();
        const win = try self.ctx.conn.createPopup(parent.win, positioner);
        errdefer win.destroy(self.ctx.allocator);

        if (width > 0) win.width = width;
        if (height > 0) win.height = height;
        try self.ctx.conn.waitReady(win);

        return try self.adoptView(id, win);
    }

    /// Create a wlr-layer-shell surface from a windowing request.
    fn createLayer(self: *App, req: *const windowing.WindowRequest) !*View {
        // The first layer window adopts the implicit view. A layer-only
        // embedder bootstraps this surface at startup; if it is missing, create
        // it lazily with the exact requested properties and never AddView it.
        if (req.preferred_view_id == 0 and !self.implicit_adopted) {
            if (self.viewForId(0)) |view| {
                // Re-adopt after a hot restart. A toplevel cannot become a
                // layer surface, so a role mismatch falls through to a new view.
                switch (view.win.role) {
                    .layer => return self.readoptLayerView(view, req),
                    .toplevel, .popup => {},
                }
            } else {
                const win = try self.createLayerWindow(req);
                var owned = true;
                errdefer if (owned) win.destroy(self.ctx.allocator);

                win.applyRequest(req);
                try self.ctx.conn.waitReady(win);
                if (win.width == 0) win.width = 800;
                if (win.height == 0) win.height = 600;

                const view = try self.adoptView(0, win);
                owned = false;
                self.implicit_adopted = true;
                view.engine_state = .added;
                self.notifyAdoptedView(view);
                view.win.resized = false;
                return view;
            }
        }

        const win = try self.createLayerWindow(req);
        var owned = true;
        errdefer if (owned) win.destroy(self.ctx.allocator);

        // The configure that `waitReady` blocks for may leave a dimension to
        // the client. Give the engine something valid to draw at; the first
        // frame can still change it.
        win.applyRequest(req);
        try self.ctx.conn.waitReady(win);
        if (win.width == 0) win.width = 800;
        if (win.height == 0) win.height = 600;

        const view = try self.adoptView(self.reserveViewId(), win);
        owned = false;

        // The initial state is returned in the handle; do not replay it as
        // events once the caller registers its callbacks.
        view.win.resized = false;
        return view;
    }

    /// Create a native layer surface from the request's state, size and
    /// namespace. The caller owns the returned window until it is adopted.
    fn createLayerWindow(self: *App, req: *const windowing.WindowRequest) !*window.Window {
        const state = req.layer_surface;
        const output = if (state.output < 0)
            null
        else blk: {
            const index: usize = @intCast(state.output);
            const outputs = self.ctx.conn.outputs.items;
            if (index >= outputs.len) return error.UnknownOutput;
            break :blk outputs[index];
        };

        const size = layerRequestSize(req);
        return self.ctx.conn.createLayer(.{
            .state = state,
            .output = output,
            .namespace = if (state.namespace) |namespace| namespace else "filo",
            .width = size.width,
            .height = size.height,
        });
    }

    /// Update the implicit view's already-created layer surface to a new
    /// request. Used on hot restart, when view 0 survives the isolate.
    fn readoptLayerView(self: *App, view: *View, req: *const windowing.WindowRequest) !*View {
        self.implicit_adopted = true;
        view.engine_state = .added;

        const state = req.layer_surface;
        const size = layerRequestSize(req);
        const current = view.win.role.layer.state;

        // Always refresh the sizing state: the new isolate may carry different
        // constraints. Then decide whether the surface itself has to change.
        view.win.applyRequest(req);
        view.content_frame_seen.store(false, .release);

        // A content-sized axis keeps its current size; a compositor-owned or
        // explicitly sized axis uses the request. This avoids shrinking a
        // content-sized surface back to its placeholder on hot restart.
        const target = windowing.Size{
            .width = if (view.win.tracksContentWidth()) view.win.width else size.width,
            .height = if (view.win.tracksContentHeight()) view.win.height else size.height,
        };

        // The startup surface may already match this request exactly. Keep it
        // as-is: reconfiguring a layer surface that was adopted before the
        // engine started races the first frame.
        const same_surface = current.layer == state.layer and
            current.anchor == state.anchor and
            current.exclusive_zone == state.exclusive_zone and
            current.keyboard_interactivity == state.keyboard_interactivity and
            current.margin_top == state.margin_top and
            current.margin_right == state.margin_right and
            current.margin_bottom == state.margin_bottom and
            current.margin_left == state.margin_left and
            current.accepts_input == state.accepts_input and
            view.win.width == target.width and
            view.win.height == target.height;

        if (!same_surface) {
            // Apply the size first so the layer-state validation sees the new
            // dimensions, then the state. Both are double-buffered and commit.
            view.win.configured = false;
            view.win.requestLayerSize(target);
            try view.win.applyLayerSurface(state);
        }

        self.notifyAdoptedView(view);
        view.win.resized = false;
        return view;
    }

    /// Create a view and tell the engine about it. Resources exist before the
    /// asynchronous add starts, so a frame presented for it can always find its
    /// surface.
    pub fn spawnView(self: *App, width: u32, height: u32) !*View {
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
            view.win.physicalWidth(),
            view.win.physicalHeight(),
            view.win.pixel_ratio,
            view.win.metricsConstraints(),
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

    pub fn deinitViews(self: *App) void {
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

    /// A hot restart destroys the Dart isolate. Every `View` still points at
    /// `NativeCallable`s registered by that isolate, and calling one afterwards
    /// jumps into unmapped code. Drop them before the engine tears the isolate
    /// down, then put the window layout back to what it is at start-up: keep
    /// the implicit view for the new isolate to adopt and remove the windows
    /// the old isolate created, which the new isolate has no handles for.
    fn resetForRestart(self: *App) void {
        self.implicit_adopted = false;

        var orphaned: usize = 0;
        for (self.views.items) |view| {
            // Views without an observer were created by the embedder itself
            // (the implicit view), not by the old isolate, so there is no
            // stale callback to drop and nothing to close.
            const dart_owned = !view.callbacks.isEmpty();
            view.callbacks = windowing.empty_callbacks;
            if (view.id == 0) {
                continue;
            }
            if (!dart_owned) continue;

            orphaned += 1;
            view.destroy_requested = true;
        }
        std.debug.print(
            "filo: hot restart; cleared callbacks, closing {} orphaned window(s)\n",
            .{orphaned},
        );
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

    /// Queue a resize to the size the raster thread just drew at. Called from
    /// `presentView`, so it must not touch Wayland or the view registry.
    fn postContentResize(self: *App, view: *View, width: u32, height: u32) void {
        if (view.content_resize_pending.swap(true, .acq_rel)) return;

        const req = std.heap.c_allocator.create(ContentResizeRequest) catch {
            view.content_resize_pending.store(false, .release);
            return;
        };
        req.* = .{
            .app = self,
            .view_id = view.id,
            .width = width,
            .height = height,
        };

        const eng = self.engine.load(.acquire) orelse {
            std.heap.c_allocator.destroy(req);
            view.content_resize_pending.store(false, .release);
            return;
        };
        eng.postMainTask(runContentResize, req);
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

        // A sized-to-content surface follows the extent the engine drew at. A
        // popup has to ask the compositor for that size before its first frame
        // can be shown; a toplevel can show the frame and then update its
        // native size and metrics.
        //
        // While a buffer-scale change is in flight the frame extent also changes
        // (logical size * new scale), which is not a content change: skip the
        // comparison until a frame at the new scale has been presented.
        const scale_transition = view.scale_transition.load(.acquire);
        const first_content_frame = !view.content_frame_seen.load(.acquire);
        // A popup already presents at the positioner's size; only reposition
        // it when the content actually differs. A toplevel always applies its
        // first frame, even when it matches the placeholder, so a non-resizable
        // window gets pinned and a resizable one ends its initial auto-size.
        const popup_role = switch (view.win.role) {
            .popup => true,
            .toplevel, .layer => false,
        };
        const force_first = first_content_frame and !popup_role;
        const content_changed =
            (view.win.tracksContentWidth() and width != view.contentWidth()) or
            (view.win.tracksContentHeight() and height != view.contentHeight());
        if (scale_transition == 0 and
            view.win.isSizedToContent() and
            (force_first or content_changed))
        {
            view.content_frame_seen.store(true, .release);
            self.postContentResize(view, width, height);
            if (popup_role) return true;
        }

        view.surface.presentLayers(width, height, layers[0..count]) catch |err| {
            std.debug.print("filo: compositor present failed for view {}: {}\n", .{ info.view_id, err });
            return false;
        };

        // The new scale is now applied. Adopt the frame just presented as the
        // content-size baseline so later frames compare like with like.
        if (scale_transition != 0 and view.surface.buffer_scale == scale_transition) {
            view.updateContentSize(width, height);
            view.scale_transition.store(0, .release);
        }
        return true;
    }

    pub fn toHost(self: *App) windowing.Host {
        return .{ .ctx = self, .vtable = .{
            .create = bridgeCreate,
            .destroy = bridgeDestroy,
            .observe = bridgeObserve,
            .set_title = bridgeSetTitle,
            .set_size = bridgeSetSize,
            .set_constraints = bridgeSetConstraints,
            .activate = bridgeActivate,
            .set_maximized = bridgeSetMaximized,
            .set_minimized = bridgeSetMinimized,
            .set_fullscreen = bridgeSetFullscreen,
            .set_parent = bridgeSetParent,
            .update_position = bridgeUpdatePosition,
            .update_layer_surface = bridgeUpdateLayerSurface,
            .get_size = bridgeGetSize,
            .get_state = bridgeGetState,
            .get_capabilities = bridgeGetCapabilities,
            .get_title = bridgeGetTitle,
            .get_offset = bridgeGetOffset,
        } };
    }

    fn bridgeCreate(
        ctx: ?*anyopaque,
        req: *windowing.WindowRequest,
        out: *windowing.WindowHandle,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        if (!app.ctx_ready) return .backend_failed;

        const kind = std.enums.fromInt(windowing.Kind, req.kind) orelse return .invalid_argument;

        const view = switch (kind) {
            .toplevel => app.createToplevel(req) catch |err| {
                std.debug.print("filo: windowing create: could not create window: {}\n", .{err});
                return switch (err) {
                    error.UnknownParent => .unknown_view,
                    else => .backend_failed,
                };
            },
            .popup => app.createPopup(req) catch |err| {
                std.debug.print("fembed: windowing create: could not create popup: {}\n", .{err});
                return switch (err) {
                    error.UnknownParent => .unknown_view,
                    error.InvalidParent => .invalid_argument,
                    else => .backend_failed,
                };
            },
            .layer => app.createLayer(req) catch |err| {
                std.debug.print("filo: windowing create: could not create layer surface: {}\n", .{err});
                return switch (err) {
                    error.LayerShellUnavailable => .unsupported,
                    error.UnknownOutput,
                    error.InvalidLayer,
                    error.InvalidSize,
                    error.InvalidKeyboardInteractivity,
                    error.UnsupportedKeyboardInteractivity,
                    => .invalid_argument,
                    else => .backend_failed,
                };
            },
        };

        if (view.engine_state == .adding) {
            std.debug.print("filo: adding view\n", .{});
            beginAddViewSync(app, view) catch |err| {
                std.debug.print("filo: windowing create: AddView failed: {}\n", .{err});
                if (err == error.AddViewNotSynchronous) {
                    @panic("Multiwindow feature needs the dart code and the embedder code to run in the same thread");
                } else {
                    app.destroyView(view);
                }
                return .backend_failed;
            };
        }

        out.view_id = view.id;
        out.content_size = .{
            .width = view.win.width,
            .height = view.win.height,
        };
        out.title = if (kind == .toplevel) view.viewTitleZ() else null;
        out.toplevel_state = switch (view.win.role) {
            .toplevel => |toplevel| toplevel.toplevelState(),
            .popup, .layer => 0,
        };
        out.wm_capabilities = switch (view.win.role) {
            .toplevel => |toplevel| toplevel.wmCapabilities(),
            .popup, .layer => 0,
        };
        out.offset_from_parent = switch (view.win.role) {
            .popup => |popup| popup.offsetFromParent(),
            .toplevel, .layer => .{ .x = 0, .y = 0 },
        };
        return .ok;
    }

    fn bridgeDestroy(ctx: ?*anyopaque, view_id: i64) void {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        if (!app.ctx_ready) return;
        const view = app.viewForId(view_id) orelse return;
        view.destroy_requested = true;
    }

    fn bridgeObserve(
        ctx: ?*anyopaque,
        view_id: i64,
        callbacks: windowing.WindowCallbacks,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        if (!app.ctx_ready) return .backend_failed;
        const view = app.viewForId(view_id) orelse return .unknown_view;
        view.callbacks = callbacks;
        return .ok;
    }

    fn bridgeSetTitle(
        ctx: ?*anyopaque,
        view_id: i64,
        title: ?[*:0]const u8,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        if (title) |value| {
            switch (view.win.role) {
                .toplevel => |*toplevel| toplevel.setTitle(value),
                .popup, .layer => {},
            }
        }
        view.setViewTitleZ(title);
        view.win.commit();
        return .ok;
    }

    fn bridgeSetSize(
        ctx: ?*anyopaque,
        view_id: i64,
        size: windowing.Size,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        // A layer surface's size is a client request. For the xdg-shell roles
        // there is no resize request, but an explicit setSize still leaves
        // content-sizing mode and asks the engine to draw at that size.
        switch (view.win.role) {
            .layer => |layer| {
                if (!window.layerSizeValid(layer.state.anchor, size.width, size.height)) {
                    return .invalid_argument;
                }
                view.win.stopSizingToContent();
                view.win.requestLayerSize(size);
                return .ok;
            },
            .toplevel, .popup => {
                view.win.applyRequestedSize(size);
                return .ok;
            },
        }
    }

    fn bridgeSetConstraints(
        ctx: ?*anyopaque,
        view_id: i64,
        min: windowing.Size,
        max: windowing.Size,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        view.win.setContentConstraints(min, max);
        switch (view.win.role) {
            .toplevel => |*toplevel| {
                toplevel.setMinSize(min);
                toplevel.setMaxSize(max);
            },
            .popup, .layer => {},
        }

        if (view.win.isSizedToContent()) {
            // The new bounds replace the ones used for loose metrics. Unpin
            // the native window, clamp the cached size so the metrics event is
            // valid, and schedule a relayout so the content can pick a new
            // size.
            view.win.clampToContentConstraints();
            switch (view.win.role) {
                .layer => view.win.applyContentSize(view.win.width, view.win.height),
                .toplevel, .popup => view.win.resized = true,
            }
        }
        view.win.commit();
        return .ok;
    }

    fn bridgeActivate(ctx: ?*anyopaque, view_id: i64) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        _ = app.viewForId(view_id) orelse return .unknown_view;
        // No xdg_activation_v1: the compositor decides whether to focus.
        return .ok;
    }

    fn bridgeSetMaximized(
        ctx: ?*anyopaque,
        view_id: i64,
        maximized: bool,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        switch (view.win.role) {
            .toplevel => |*toplevel| toplevel.setMaximized(maximized),
            .popup, .layer => {},
        }
        view.win.commit();
        return .ok;
    }

    fn bridgeSetMinimized(
        ctx: ?*anyopaque,
        view_id: i64,
        minimized: bool,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        switch (view.win.role) {
            .toplevel => |*toplevel| toplevel.setMinimized(minimized),
            .popup, .layer => {},
        }
        view.win.commit();
        return .ok;
    }

    fn bridgeSetFullscreen(
        ctx: ?*anyopaque,
        view_id: i64,
        fullscreen: bool,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        switch (view.win.role) {
            .toplevel => |*toplevel| toplevel.setFullscreen(fullscreen),
            .popup, .layer => {},
        }
        view.win.commit();
        return .ok;
    }

    fn bridgeSetParent(
        ctx: ?*anyopaque,
        view_id: i64,
        parent_view_id: i64,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        const parent_toplevel: ?*window.Window.Toplevel = if (parent_view_id < 0)
            null
        else blk: {
            const parent = app.viewForId(parent_view_id) orelse return .unknown_view;
            break :blk switch (parent.win.role) {
                .toplevel => |*toplevel| toplevel,
                .popup, .layer => null,
            };
        };
        switch (view.win.role) {
            .toplevel => |*toplevel| toplevel.setParent(parent_toplevel),
            .popup, .layer => {},
        }
        view.win.commit();
        return .ok;
    }

    fn bridgeUpdatePosition(
        ctx: ?*anyopaque,
        view_id: i64,
        anchor: ?*const windowing.Rect,
        positioner: ?*const windowing.Positioner,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        const popup = switch (view.win.role) {
            .popup => |*popup| popup,
            .toplevel, .layer => return .unsupported,
        };

        var request = popup.positioner;
        if (positioner) |value| request = value.*;
        if (anchor) |value| request.anchor_rect = value.*;
        if (view.win.isSizedToContent()) {
            // The surface size belongs to the content, not to the positioning
            // request. Keeping the current size here prevents a later
            // `updatePosition` from shrinking the popup back to its initial
            // placeholder.
            request.size = .{ .width = view.win.width, .height = view.win.height };
        }

        const xdg_positioner = makePositioner(app, request) catch return .backend_failed;
        defer xdg_positioner.destroy();

        popup.reposition(xdg_positioner);
        popup.positioner = request;
        view.win.commit();
        return .ok;
    }

    fn bridgeUpdateLayerSurface(
        ctx: ?*anyopaque,
        view_id: i64,
        layer: *const windowing.LayerSurface,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        switch (view.win.role) {
            .layer => {},
            .toplevel, .popup => return .unsupported,
        }
        // The input region is a wl_surface request, not layer-shell state.
        app.ctx.conn.setSurfaceInputRegion(view.win.surface, layer.accepts_input != 0) catch
            return .backend_failed;
        view.win.applyLayerSurface(layer.*) catch |err| return switch (err) {
            error.InvalidLayer,
            error.InvalidSize,
            error.InvalidKeyboardInteractivity,
            error.UnsupportedKeyboardInteractivity,
            => .invalid_argument,
        };
        return .ok;
    }

    fn bridgeGetSize(
        ctx: ?*anyopaque,
        view_id: i64,
        out: *windowing.Size,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        out.* = .{
            .width = @intCast(view.win.width),
            .height = @intCast(view.win.height),
        };
        return .ok;
    }

    fn bridgeGetState(ctx: ?*anyopaque, view_id: i64, out: *u32) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        out.* = switch (view.win.role) {
            .toplevel => |toplevel| toplevel.toplevelState(),
            .popup, .layer => 0,
        };
        return .ok;
    }

    fn bridgeGetCapabilities(ctx: ?*anyopaque, view_id: i64, out: *u32) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        out.* = switch (view.win.role) {
            .toplevel => |toplevel| toplevel.wmCapabilities(),
            .popup, .layer => 0,
        };
        return .ok;
    }

    fn bridgeGetTitle(
        ctx: ?*anyopaque,
        view_id: i64,
        buf: [*]u8,
        len: u32,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        if (len == 0) return .ok;
        const n = @min(std.mem.len(view.viewTitleZ()), @as(usize, len) - 1);
        @memcpy(buf[0..n], view.title[0..n]);
        buf[n] = 0;
        return .ok;
    }

    fn bridgeGetOffset(
        ctx: ?*anyopaque,
        view_id: i64,
        out: *windowing.Offset,
    ) windowing.Status {
        const app: *App = @ptrCast(@alignCast(ctx.?));
        const view = app.viewForId(view_id) orelse return .unknown_view;
        out.* = switch (view.win.role) {
            .popup => |popup| popup.offsetFromParent(),
            .toplevel, .layer => .{ .x = 0, .y = 0 },
        };
        return .ok;
    }
};

/// Build an `xdg_positioner` from the ABI positioner. The caller owns and
/// destroys it.
fn makePositioner(app: *App, p: windowing.Positioner) !*xdg.Positioner {
    const positioner = try app.ctx.conn.wm_base.createPositioner();
    errdefer positioner.destroy();

    positioner.setSize(@intCast(p.size.width), @intCast(p.size.height));
    positioner.setAnchorRect(
        p.anchor_rect.x,
        p.anchor_rect.y,
        p.anchor_rect.width,
        p.anchor_rect.height,
    );
    positioner.setAnchor(anchorFromInt(p.anchor));
    positioner.setGravity(gravityFromInt(p.gravity));
    positioner.setConstraintAdjustment(@bitCast(p.constraint_adjustment));
    positioner.setOffset(p.offset.x, p.offset.y);
    return positioner;
}

/// Pick the size to request for one layer-surface dimension.
///
/// A zero request is only legal for a dimension anchored to opposite edges; in
/// that case the compositor chooses the size. Otherwise fall back to the
/// minimum constraint (content sizing) or a sane default, so the initial commit
/// is always valid.
fn layerDimension(
    requested: u32,
    opposite_anchors: bool,
    sized_to_content: bool,
    minimum: u32,
    fallback: u32,
) u32 {
    if (requested != 0) return @min(requested, 16_384);
    // Anchoring to opposite edges makes the compositor own the dimension, even
    // when the window otherwise sizes to its content.
    if (opposite_anchors) return 0;
    if (sized_to_content) return @max(1, minimum);
    return fallback;
}

/// The size to request for a layer surface, following its anchors.
fn layerRequestSize(req: *const windowing.WindowRequest) windowing.Size {
    const state = req.layer_surface;
    const anchors = state.anchor;
    const horizontal = anchors & windowing.LayerAnchor.left != 0 and
        anchors & windowing.LayerAnchor.right != 0;
    const vertical = anchors & windowing.LayerAnchor.top != 0 and
        anchors & windowing.LayerAnchor.bottom != 0;
    const sized_to_content = req.sized_to_content != 0;
    return .{
        .width = layerDimension(
            req.size.width,
            horizontal,
            sized_to_content,
            @max(1, @min(req.min_size.width, max_content_size)),
            800,
        ),
        .height = layerDimension(
            req.size.height,
            vertical,
            sized_to_content,
            @max(1, @min(req.min_size.height, max_content_size)),
            600,
        ),
    };
}

fn anchorFromInt(value: i32) xdg.Positioner.Anchor {
    return switch (value) {
        0 => .none,
        1 => .top,
        2 => .bottom,
        3 => .left,
        4 => .right,
        5 => .top_left,
        6 => .bottom_left,
        7 => .top_right,
        8 => .bottom_right,
        else => .none,
    };
}

fn gravityFromInt(value: i32) xdg.Positioner.Gravity {
    return switch (value) {
        0 => .none,
        1 => .top,
        2 => .bottom,
        3 => .left,
        4 => .right,
        5 => .top_left,
        6 => .bottom_left,
        7 => .top_right,
        8 => .bottom_right,
        else => .none,
    };
}

const ViewOpKind = enum { add, remove };

/// Baton for one asynchronous AddView/RemoveView operation.
const ViewOp = struct {
    app: *App,
    view: *View,
    kind: ViewOpKind,
    ok: bool = false,
};

/// Baton for a resize requested by a rendered frame. `width`/`height` are the
/// physical backing-store extent; `runContentResize` converts them to logical
/// before touching xdg-shell or layer-shell.
const ContentResizeRequest = struct {
    app: *App,
    view_id: engine.ViewId,
    width: u32,
    height: u32,
};

fn runContentResize(user_data: ?*anyopaque) void {
    const req: *ContentResizeRequest = @ptrCast(@alignCast(user_data.?));
    defer std.heap.c_allocator.destroy(req);

    const view = req.app.viewForId(req.view_id) orelse return;
    if (!view.win.isSizedToContent()) {
        view.content_resize_pending.store(false, .release);
        return;
    }

    // `req` is the extent the raster thread drew at, in physical pixels.
    const physical_width = @max(1, @min(req.width, 16_384));
    const physical_height = @max(1, @min(req.height, 16_384));
    // Wayland surface and positioner sizes are surface-local/logical.
    const width = scale.logical(physical_width, view.win.pixel_ratio);
    const height = scale.logical(physical_height, view.win.pixel_ratio);

    switch (view.win.role) {
        .popup => |*popup| {
            var positioner = popup.positioner;
            positioner.size = .{ .width = width, .height = height };

            const xdg_positioner = makePositioner(req.app, positioner) catch {
                view.content_resize_pending.store(false, .release);
                return;
            };
            defer xdg_positioner.destroy();

            popup.reposition(xdg_positioner);
            popup.positioner = positioner;
            view.win.commit();
            // The popup keeps its content-sized baseline even if the compositor
            // adjusts the final geometry in its configure; otherwise the next
            // identical frame would request another reposition.
            view.updateContentSize(physical_width, physical_height);
            // The configure event that follows clears the pending flag and
            // sends the new metrics.
            return;
        },
        .toplevel, .layer => {},
    }

    view.win.applyContentSize(width, height);
    view.updateContentSize(physical_width, physical_height);
    if (view.win.resizable) {
        // A resizable sized-to-content toplevel only auto-sizes once. From now
        // on the user drives the size and Flutter fills the window, so switch
        // the metrics back to tight constraints.
        view.win.stopSizingToContent();
    }
    view.content_resize_pending.store(false, .release);
}

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
            view.engine_state = .added;
            std.debug.print("filo: view {} added\n", .{view.id});
            if (view.close_after_add) view.win.closing = true;
        } else {
            std.debug.print("filo: view {} could not be added\n", .{view.id});
            app.destroyView(view);
        },
        .remove => if (op.ok) {
            std.debug.print("filo: view {} removed\n", .{view.id});
            if (view.callbacks) |callbacks| {
                if (callbacks.on_destroy) |on_destroy| on_destroy();
            }
            app.destroyView(view);
        } else {
            std.debug.print("filo: view {} could not be removed\n", .{view.id});
            view.engine_state = .remove_failed;
        },
    }

    app.ctx.allocator.destroy(op);
}

//------------------------------------------------------------------------------
// filo_windowing bridge
//------------------------------------------------------------------------------

/// The callback `AddView` invokes. On this embedder it runs inline, on the main
/// thread, before `Engine.addView` returns. The `*View` is the baton and is
/// stable for the view's whole life, so an unexpected late dispatch is still
/// safe (it just sets the flag later).
fn addViewSyncCallback(result: [*c]const c.FlutterAddViewResult) callconv(.c) void {
    if (result == null or result.*.user_data == null) return;
    const view: *View = @ptrCast(@alignCast(result.*.user_data.?));
    if (result.*.added) {
        view.engine_state = .added;
    } else {
        view.engine_state = .add_failed;
    }
}

/// Add a view and require the engine to have finished before returning. This is
/// only synchronous because the UI task runner is the main thread (see the
/// task-runner comment in `engine.zig`): `RunNowOrPostTask` runs the add task
/// inline.
fn beginAddViewSync(self: *App, view: *View) !void {
    try self.ctx.eng.addView(
        view.id,
        view.win.physicalWidth(),
        view.win.physicalHeight(),
        view.win.pixel_ratio,
        view.win.metricsConstraints(),
        view,
        addViewSyncCallback,
    );
    switch (view.engine_state) {
        .added => return,
        .add_failed => return error.AddViewFailed,
        else => return error.AddViewNotSynchronous,
    }
}

/// `FILO_WINDOWING_SPIKE`: exercise the exported create path from the event
/// loop. It proves the view is added synchronously and that the bridge can be
/// reached through the same C entry points Dart uses.
fn runWindowingSpike(self: *App) void {
    var request = std.mem.zeroes(windowing.WindowRequest);
    request.kind = @backingInt(windowing.Kind.toplevel);
    request.size = .{ .width = 640, .height = 480 };
    request.resizable = 1;
    request.decorated = 1;
    request.title = "filo windowing spike";
    request.preferred_view_id = -1;

    var handle = std.mem.zeroes(windowing.WindowHandle);
    const result = windowing.filo_window_create(&request, &handle);
    const added = if (self.viewForId(handle.view_id)) |view| view.engine_state == .added else false;
    std.debug.print(
        "filo: windowing spike create rc={} view={} added_synchronously={}\n",
        .{ result, handle.view_id, added },
    );
    if (result != 0) return;

    _ = windowing.filo_window_observe(
        handle.view_id,
        spikeOnConfigure,
        spikeOnState,
        spikeOnCapabilities,
        null,
        spikeOnMoved,
        spikeOnClose,
        null,
    );

    _ = windowing.filo_window_set_title(handle.view_id, "filo windowing spike");
    _ = windowing.filo_window_set_constraints(handle.view_id, 320, 240, 1920, 1080);
    _ = windowing.filo_window_set_maximized(handle.view_id, 1);

    var size = std.mem.zeroes(windowing.Size);
    var state: u32 = 0;
    var capabilities: u32 = 0;
    _ = windowing.filo_window_get_size(handle.view_id, &size);
    _ = windowing.filo_window_get_state(handle.view_id, &state);
    _ = windowing.filo_window_get_capabilities(handle.view_id, &capabilities);
    std.debug.print(
        "filo: windowing spike state={b} capabilities={b} size={}x{}\n",
        .{ state, capabilities, size.width, size.height },
    );

    // A popup attached to that toplevel: xdg_popup + xdg_positioner.
    var popup_request = std.mem.zeroes(windowing.WindowRequest);
    popup_request.kind = @backingInt(windowing.Kind.popup);
    popup_request.size = .{ .width = 200, .height = 120 };
    popup_request.parent_view_id = handle.view_id;
    popup_request.decorated = 0;
    popup_request.positioner = .{
        .size = .{ .width = 200, .height = 120 },
        .anchor_rect = .{ .x = 10, .y = 10, .width = 100, .height = 30 },
        .anchor = 2, // bottom
        .gravity = 1, // top
        .constraint_adjustment = 0,
        .offset = .{ .x = 0, .y = 0 },
    };

    var popup_handle = std.mem.zeroes(windowing.WindowHandle);
    const popup_result = windowing.filo_window_create(&popup_request, &popup_handle);
    std.debug.print(
        "filo: windowing spike popup rc={} view={} offset={},{}\n",
        .{
            popup_result,
            popup_handle.view_id,
            popup_handle.offset_from_parent.x,
            popup_handle.offset_from_parent.y,
        },
    );

    if (popup_result == 0) {
        _ = windowing.filo_window_observe(
            popup_handle.view_id,
            spikeOnConfigure,
            spikeOnState,
            spikeOnCapabilities,
            null,
            spikeOnMoved,
            spikeOnClose,
            null,
        );
        _ = windowing.filo_window_update_position(
            popup_handle.view_id,
            null,
            &popup_request.positioner,
        );
        var offset = std.mem.zeroes(windowing.Offset);
        _ = windowing.filo_window_get_offset(popup_handle.view_id, &offset);
        std.debug.print(
            "filo: windowing spike popup offset after update={},{}\n",
            .{ offset.x, offset.y },
        );
        _ = windowing.filo_window_destroy(popup_handle.view_id);
    }

    // A layer surface: zwlr_layer_shell_v1, anchored to the top-right.
    var layer_request = std.mem.zeroes(windowing.WindowRequest);
    layer_request.kind = @backingInt(windowing.Kind.layer);
    layer_request.size = .{ .width = 0, .height = 200 };
    layer_request.min_size = .{ .width = 1, .height = 1 };
    layer_request.decorated = 0;
    layer_request.preferred_view_id = -1;
    layer_request.layer_surface = .{
        .layer = @backingInt(windowing.Layer.top),
        .anchor = windowing.LayerAnchor.top |
            windowing.LayerAnchor.left |
            windowing.LayerAnchor.right,
        .exclusive_zone = 0,
        .keyboard_interactivity = @backingInt(windowing.LayerKeyboardInteractivity.on_demand),
        .margin_top = 16,
        .margin_right = 16,
        .margin_bottom = 0,
        .margin_left = 0,
        .output = -1,
        .namespace = "filo layer spike",
        .accepts_input = 1,
    };

    var layer_handle = std.mem.zeroes(windowing.WindowHandle);
    const layer_result = windowing.filo_window_create(&layer_request, &layer_handle);
    std.debug.print(
        "filo: windowing spike layer rc={} view={} size={}x{}\n",
        .{
            layer_result,
            layer_handle.view_id,
            layer_handle.content_size.width,
            layer_handle.content_size.height,
        },
    );

    if (layer_result == 0) {
        _ = windowing.filo_window_observe(
            layer_handle.view_id,
            spikeOnConfigure,
            spikeOnState,
            spikeOnCapabilities,
            null,
            spikeOnMoved,
            spikeOnClose,
            null,
        );

        var moved = layer_request.layer_surface;
        moved.layer = @backingInt(windowing.Layer.bottom);
        moved.anchor = windowing.LayerAnchor.left | windowing.LayerAnchor.right;
        moved.exclusive_zone = -1;
        _ = windowing.filo_window_update_layer_surface(layer_handle.view_id, &moved);

        var layer_size = std.mem.zeroes(windowing.Size);
        _ = windowing.filo_window_get_size(layer_handle.view_id, &layer_size);
        std.debug.print(
            "filo: windowing spike layer size after update={}x{}\n",
            .{ layer_size.width, layer_size.height },
        );
        _ = windowing.filo_window_destroy(layer_handle.view_id);
    }

    _ = windowing.filo_window_destroy(handle.view_id);
}

fn spikeOnConfigure(width: i32, height: i32) callconv(.c) void {
    std.debug.print("filo: windowing spike on_configure={}x{}\n", .{ width, height });
}

fn spikeOnState(state: u32) callconv(.c) void {
    std.debug.print("filo: windowing spike on_state={b}\n", .{state});
}

fn spikeOnCapabilities(capabilities: u32) callconv(.c) void {
    std.debug.print("filo: windowing spike on_capabilities={b}\n", .{capabilities});
}

fn spikeOnMoved(x: i32, y: i32) callconv(.c) void {
    std.debug.print("filo: windowing spike on_moved={},{}\n", .{ x, y });
}

fn spikeOnClose() callconv(.c) void {
    std.debug.print("filo: windowing spike on_close\n", .{});
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
pub fn createBackingStore(
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
        std.debug.print("filo: could not create backing store: {}\n", .{err});
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
pub fn collectBackingStore(
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

pub fn presentViewCallback(info: [*c]const c.FlutterPresentViewInfo) callconv(.c) bool {
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

pub fn rendererConfig(vk_ctx: *vulkan.Context) c.FlutterRendererConfig {
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
pub fn viewForSurface(user_data: ?*anyopaque, surface: *wl.Surface) ?engine.ViewId {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const view = app.views_by_surface.get(surface) orelse return null;
    return view.id;
}

/// The buffer scale of the view that owns `surface`, for pointer events. The
/// pointer must convert its surface-local position to the physical pixels the
/// Flutter embedder expects.
pub fn viewScaleForSurface(user_data: ?*anyopaque, surface: *wl.Surface) f64 {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const view = app.views_by_surface.get(surface) orelse return 1.0;
    return view.win.pixel_ratio;
}

/// Invoked by the engine (on the engine thread) for every platform message the
/// framework sends to the embedder. Every message must be answered; the actual
/// routing lives in `flutter/platform_channel.zig`.
pub fn platformMessageCallback(
    message: [*c]const c.FlutterPlatformMessage,
    user_data: ?*anyopaque,
) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    app.channels.handle(message);
}

/// Invoked by the engine right before a hot restart. The Dart isolate that
/// registered the window callbacks is about to go away; clear them so no
/// native event can call into it afterwards.
pub fn onPreEngineRestart(user_data: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    app.resetForRestart();
}

/// Invoked by the engine on its raster thread when it wants to start a frame at
/// the display's next refresh. It hands back a baton, and the engine waits for
/// it; `FlutterEngineOnVsync` may only be called on the main thread, so the
/// baton is queued for the event loop, which answers it from the compositor's
/// frame clock.
pub fn vsyncCallback(user_data: ?*anyopaque, baton: isize) callconv(.c) void {
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
pub fn viewFocusChangeRequestCallback(
    request: [*c]const c.FlutterViewFocusChangeRequest,
    user_data: ?*anyopaque,
) callconv(.c) void {
    _ = user_data;
    if (request == null) return;

    const state: c_int = @intCast(request.*.state);
    const direction: c_int = @intCast(request.*.direction);
    std.debug.print("filo: view {} focus request: {s} ({s})\n", .{
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

const AdoptViewRequest = struct {
    app: *App,
    view: *View,
};

/// Publish the first metrics for a view the first controller adopted as the
/// implicit view. Runs from the main task queue, outside any Dart callback.
fn runAdoptViewMetrics(user_data: ?*anyopaque) void {
    const req: *AdoptViewRequest = @ptrCast(@alignCast(user_data.?));
    defer std.heap.c_allocator.destroy(req);

    const app = req.app;
    const view = req.view;
    app.ctx.eng.sendWindowMetricsForView(
        view.id,
        view.win.physicalWidth(),
        view.win.physicalHeight(),
        view.win.pixel_ratio,
        view.win.metricsConstraints(),
    );
    app.ctx.eng.scheduleFrame();
}

const CreateWindowRequest = struct {
    app: *App,
    width: u32,
    height: u32,
};

pub fn onCreateWindow(user_data: ?*anyopaque, width: u32, height: u32) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    const req = std.heap.c_allocator.create(CreateWindowRequest) catch return;
    req.* = .{ .app = app, .width = width, .height = height };
    app.ctx.eng.postMainTask(runCreateWindow, req);
}

fn runCreateWindow(user_data: ?*anyopaque) void {
    const req: *CreateWindowRequest = @ptrCast(@alignCast(user_data.?));
    defer std.heap.c_allocator.destroy(req);
    _ = req.app.spawnView(req.width, req.height) catch |err| {
        std.debug.print("filo: could not create window: {}\n", .{err});
    };
}

const CloseWindowRequest = struct {
    app: *App,
    view_id: engine.ViewId,
};

pub fn onCloseWindow(user_data: ?*anyopaque, view_id: engine.ViewId) void {
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
    switch (view.engine_state) {
        .adding => view.close_after_add = true,
        .added => view.win.closing = true,
        .add_failed, .removing, .remove_failed => {},
    }
}

const CursorRequest = struct {
    conn: *connection.Connection,
    cursor: mouse_cursor.Cursor,
};

pub fn onSetCursor(user_data: ?*anyopaque, cursor: mouse_cursor.Cursor) void {
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
    if (self.views.items.len == 0 and self.saw_view) {
        // A process with no window yet stays alive until Dart creates one;
        // once a view has existed, zero views means the app is done.
        loop.stop();
        return;
    }

    if (self.windowing_spike and !self.windowing_spike_done) {
        self.windowing_spike_done = true;
        runWindowingSpike(self);
    }

    // The compositor changed the output scale. Windows that receive a
    // per-surface preferred scale follow it themselves; the output-wide value
    // is only a fallback for older compositors.
    if (self.ctx.conn.scale_dirty) {
        self.ctx.conn.scale_dirty = false;
        const ratio: f64 = @floatFromInt(self.ctx.conn.display_scale);
        for (self.views.items) |view| {
            if (!view.win.scale_from_compositor) view.win.setPixelRatio(ratio);
        }
    }

    for (self.views.items) |view| {
        // A compositor close request is not a destroy: tell the app and let it
        // decide. Without an observer (the legacy `filo/windows` path) keep
        // the old auto-remove behaviour.
        if (view.win.closing) {
            view.win.closing = false;
            if (!view.destroy_requested) {
                if (view.callbacks.on_close) |on_close| {
                    on_close();
                } else if (view.id == 0) {
                    loop.stop();
                    return;
                } else {
                    view.destroy_requested = true;
                }
            }
        }

        // A dismissed popup is already gone from the compositor's point of
        // view (the `popup_done` event says the client should destroy it), so
        // tear the view down. The controller sees the `on_destroy` event.
        switch (view.win.role) {
            .popup => |*popup| {
                if (popup.done) {
                    popup.done = false;
                    view.destroy_requested = true;
                }
            },
            .toplevel, .layer => {},
        }

        if (view.destroy_requested) {
            if (view.id == 0) {
                loop.stop();
                return;
            }
            switch (view.engine_state) {
                // The engine is still adding this view; remove it once the add
                // callback says it exists.
                .adding => view.close_after_add = true,
                .added => {
                    view.engine_state = .removing;
                    self.beginRemoveView(view) catch |err| {
                        std.debug.print("filo: could not remove view {}: {}\n", .{ view.id, err });
                        view.engine_state = .remove_failed;
                    };
                },
                .removing, .remove_failed, .add_failed => {},
            }
            continue;
        }
        if (view.engine_state == .added) view.emitWindowEvents(self.ctx.eng);
    }

    self.ctx.eng.frame_period_ns = self.ctx.conn.frame_period_ns;
    if (self.frame_clock) |clock| {
        clock.setPeriod(self.ctx.conn.frame_period_ns);
        clock.service();
    }
    self.ctx.conn.flush();
}

/// A callback cannot hand an error back to the loop, so remember it and stop;
/// the caller returns it once the loop comes back.
fn fail(self: *App, loop: *ev.Loop, err: anyerror) void {
    self.err = err;
    loop.stop();
}

/// Register the loop's two sources and run until the loop stops.
pub fn runLoop(app: *App) !void {
    if (app.loop_sources_added) return error.AlreadyRunning;
    app.loop_sources_added = true;

    // The loop's two sources: the display fd and the engine's task eventfd.
    app.display_probe = .init(app.ctx.conn.getFd(), .read);
    app.display_probe.c.userdata = app;
    app.display_probe.c.callback = onDisplayReadable;
    app.display_probe.c.flags.rearm = true;
    app.ctx.loop.add(&app.display_probe.c);

    app.platform_probe = .init(app.ctx.eng.getPlatformEventFd(), .read);
    app.platform_probe.c.userdata = app;
    app.platform_probe.c.callback = onPlatformWake;
    app.platform_probe.c.flags.rearm = true;
    app.ctx.loop.add(&app.platform_probe.c);

    std.debug.print("filo: entering event loop\n", .{});
    try app.ctx.loop.run();
    if (app.err) |err| return err;
}

/// Stop the running loop. Safe to call from any thread: the engine's eventfd
/// wakes the loop and the stop happens on the loop's own thread.
pub fn requestStop(app: *App) void {
    app.ctx.eng.postMainTask(stopLoop, app);
}

fn stopLoop(user_data: ?*anyopaque) void {
    const app: *App = @ptrCast(@alignCast(user_data.?));
    app.ctx.loop.stop();
}

test "a layer dimension follows its anchors before content sizing" {
    const testing = std.testing;

    // An explicit size wins.
    try testing.expectEqual(@as(u32, 320), layerDimension(320, true, true, 10, 800));
    // Opposite anchors hand the dimension to the compositor, even for a
    // content-sized surface.
    try testing.expectEqual(@as(u32, 0), layerDimension(0, true, true, 10, 800));
    // Content sizing without opposite anchors uses the minimum as a
    // placeholder until the first frame.
    try testing.expectEqual(@as(u32, 10), layerDimension(0, false, true, 10, 800));
    // Otherwise a sane default keeps the initial commit valid.
    try testing.expectEqual(@as(u32, 800), layerDimension(0, false, false, 10, 800));
    try testing.expectEqual(@as(u32, 1), layerDimension(0, false, true, 0, 800));
}
