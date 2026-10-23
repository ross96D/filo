const std = @import("std");

const manifest = @import("manifest.zig");

const c = @import("flutter");

const GetProcAddressesFn = *const fn (*c.FlutterEngineProcTable) callconv(.c) c.FlutterEngineResult;

/// Command line switches handed to the engine. Impeller is opt-in: without
/// `--enable-impeller` the engine renders with Skia.
const skia_switches = [_][*:0]const u8{"fembed"};
const impeller_switches = [_][*:0]const u8{
    "fembed",
    "--enable-impeller",
};

/// A task queue that bridges the engine's platform task runner to our main
/// (Wayland) thread. The engine posts platform tasks from its own threads; we
/// collect them here and execute them via `FlutterEngineRunTask` from the event
/// loop, using an eventfd to wake the loop.
const TaskRunner = struct {
    mutex: std.atomic.Mutex = .unlocked,
    list: std.ArrayListUnmanaged(c.FlutterTask) = .empty,
    eventfd: std.posix.fd_t,
    main_thread: std.Thread.Id,

    fn lock(self: *TaskRunner) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn post(self: *TaskRunner, task: c.FlutterTask) void {
        self.lock();
        self.list.append(std.heap.c_allocator, task) catch {
            self.mutex.unlock();
            return;
        };
        self.mutex.unlock();

        var one: u64 = 1;
        _ = std.os.linux.write(self.eventfd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
    }
};

fn taskRunnerRunsOnCurrentThread(user_data: ?*anyopaque) callconv(.c) bool {
    const runner: *TaskRunner = @ptrCast(@alignCast(user_data.?));
    return std.Thread.getCurrentId() == runner.main_thread;
}

fn taskRunnerPostTask(task: c.FlutterTask, target_time_ns: u64, user_data: ?*anyopaque) callconv(.c) void {
    _ = target_time_ns;
    const runner: *TaskRunner = @ptrCast(@alignCast(user_data.?));
    runner.post(task);
}

/// The refresh period to assume before the window has told us what the display
/// actually runs at. 60 Hz is the engine's own fallback, so this only makes the
/// startup timestamps no worse than not having a vsync source at all.
pub const default_frame_period_ns = 16_666_666;

/// The identifier of one Flutter view. The implicit view is always 0; any
/// additional views are added and removed through `Engine.addView` and
/// `Engine.removeView`.
pub const ViewId = c.FlutterViewId;

/// Whether a view has platform (keyboard) focus.
pub const ViewFocusState = enum(c.FlutterViewFocusState) {
    unfocused = @intCast(c.kUnfocused),
    focused = @intCast(c.kFocused),
};

/// The direction focus moved in, when it moved between views because of a
/// traversal such as Tab or Shift+Tab.
pub const ViewFocusDirection = enum(c.FlutterViewFocusDirection) {
    none = @intCast(c.kUndefined),
    forward = @intCast(c.kForward),
    backward = @intCast(c.kBackward),
};

/// Called when an add-view operation finishes. `user_data` is the baton passed
/// to `Engine.addView`.
pub const AddViewCallback = *const fn (result: [*c]const c.FlutterAddViewResult) callconv(.c) void;

/// Called when a remove-view operation finishes. `user_data` is the baton
/// passed to `Engine.removeView`.
pub const RemoveViewCallback = *const fn (result: [*c]const c.FlutterRemoveViewResult) callconv(.c) void;

/// A callback queued for the thread that owns the Wayland connection and the
/// Vulkan surfaces. Engine callbacks (view add/remove, platform messages) can
/// run on engine-managed threads, so they hand work here instead of touching
/// those resources directly.
pub const MainTask = struct {
    callback: *const fn (user_data: ?*anyopaque) void,
    user_data: ?*anyopaque,
};

/// Bounds sent with a window metrics event. A null set of bounds means the
/// engine should treat the current size as tight, which is the normal case for
/// a window the user can resize.
pub const WindowConstraints = struct {
    min_width: usize = 0,
    min_height: usize = 0,
    max_width: usize = 0,
    max_height: usize = 0,
};

fn windowMetrics(
    view_id: ViewId,
    width: usize,
    height: usize,
    dpr: f64,
    constraints: ?WindowConstraints,
) c.FlutterWindowMetricsEvent {
    const bounds = constraints orelse WindowConstraints{};
    return .{
        .struct_size = @sizeOf(c.FlutterWindowMetricsEvent),
        .width = width,
        .height = height,
        .pixel_ratio = dpr,
        .left = 0,
        .top = 0,
        .physical_view_inset_top = 0.0,
        .physical_view_inset_right = 0.0,
        .physical_view_inset_bottom = 0.0,
        .physical_view_inset_left = 0.0,
        .display_id = 0,
        .view_id = view_id,
        .has_constraints = constraints != null,
        .min_width_constraint = bounds.min_width,
        .min_height_constraint = bounds.min_height,
        .max_width_constraint = bounds.max_width,
        .max_height_constraint = bounds.max_height,
    };
}

fn viewFocusEvent(
    view_id: ViewId,
    state: ViewFocusState,
    direction: ViewFocusDirection,
) c.FlutterViewFocusEvent {
    return .{
        .struct_size = @sizeOf(c.FlutterViewFocusEvent),
        .view_id = view_id,
        .state = @backingInt(state),
        .direction = @backingInt(direction),
    };
}

pub const Engine = struct {
    lib: std.DynLib,
    procs: c.FlutterEngineProcTable,
    handle: c.FlutterEngine,
    aot_data: c.FlutterEngineAOTData,
    task_runner: TaskRunner,
    task_runner_description: c.FlutterTaskRunnerDescription,
    custom_task_runners: c.FlutterCustomTaskRunners,
    /// Batons handed to us by the engine's `vsync_callback`, waiting for the
    /// display's next frame. The engine calls the callback on its raster thread,
    /// while `FlutterEngineOnVsync` may only be called on the thread that
    /// started the engine, so they queue here until the event loop answers them.
    vsync_mutex: std.atomic.Mutex = .unlocked,
    vsync_batons: std.ArrayListUnmanaged(isize) = .empty,
    /// Work from engine callbacks that has to run on the Wayland/Vulkan thread.
    /// Drained by `drainPlatformTasks`, alongside the engine's platform tasks.
    main_mutex: std.atomic.Mutex = .unlocked,
    main_tasks: std.ArrayListUnmanaged(MainTask) = .empty,
    /// How far apart display refreshes are. Set by the window once it knows,
    /// which is also what the timestamps handed back use.
    frame_period_ns: u64 = default_frame_period_ns,
    /// Where `main` keeps the engine pointer the vsync callback reaches it by.
    /// Cleared at teardown so a late callback cannot touch freed memory; the
    /// callback reads it from another thread, hence the atomic.
    self_slot: *std.atomic.Value(?*Engine),

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: manifest.Config,
        renderer: *const c.FlutterRendererConfig,
        /// The engine renders each view into embedder-supplied backing stores
        /// and asks us to composite them (`present_view_callback`) instead of
        /// drawing straight into the swapchain.
        compositor: *const c.FlutterCompositor,
        user_data: ?*anyopaque,
        /// Filled in before the engine is initialized: the vsync callback runs on
        /// the raster thread and reaches the engine through this slot, and the
        /// engine can ask for a frame before `init` has returned.
        self_slot: *std.atomic.Value(?*Engine),
        platform_message_callback: c.FlutterPlatformMessageCallback,
        vsync_callback: c.VsyncCallback,
        /// Called when the framework wants the native view focus changed, for
        /// example after a focus traversal or a programmatic focus request.
        view_focus_change_request_callback: c.FlutterViewFocusChangeRequestCallback,
    ) !*Engine {
        const self = try allocator.create(Engine);
        errdefer allocator.destroy(self);

        self.* = .{
            .lib = undefined,
            .procs = undefined,
            .handle = undefined,
            .aot_data = null,
            .task_runner = undefined,
            .task_runner_description = undefined,
            .custom_task_runners = undefined,
            .self_slot = self_slot,
        };
        self_slot.*.store(self, .release);
        errdefer self_slot.*.store(null, .release);

        self.lib = try std.DynLib.open(cfg.engine_lib);
        errdefer self.lib.close();

        const get_proc_addresses: GetProcAddressesFn = self.lib.lookup(
            GetProcAddressesFn,
            "FlutterEngineGetProcAddresses",
        ) orelse return error.SymbolNotFound;

        var procs: c.FlutterEngineProcTable = std.mem.zeroes(c.FlutterEngineProcTable);
        procs.struct_size = @sizeOf(c.FlutterEngineProcTable);
        if (get_proc_addresses(&procs) != 0) return error.ProcTableInitFailed;
        self.procs = procs;

        if (cfg.aot_lib) |aot_lib_path| {
            const aot_lib_z = try allocator.dupeSentinel(u8, aot_lib_path, 0);
            defer allocator.free(aot_lib_z);
            var source: c.FlutterEngineAOTDataSource = .{
                .type = c.kFlutterEngineAOTDataSourceTypeElfPath,
                .unnamed_0 = .{ .elf_path = aot_lib_z.ptr },
            };
            if (self.procs.CreateAOTData.?(&source, &self.aot_data) != 0)
                return error.CreateAOTDataFailed;
        }

        // Set up the platform task runner before the engine is initialized, so
        // its `user_data`/struct addresses remain stable (Engine is heap
        // allocated).
        const eventfd_raw = std.os.linux.eventfd(0, std.os.linux.EFD.CLOEXEC);
        if (std.os.linux.errno(eventfd_raw) != .SUCCESS) return error.EventFdCreateFailed;
        self.task_runner = .{
            .eventfd = @intCast(eventfd_raw),
            .main_thread = std.Thread.getCurrentId(),
        };

        self.task_runner_description = .{
            .struct_size = @sizeOf(c.FlutterTaskRunnerDescription),
            .user_data = &self.task_runner,
            .runs_task_on_current_thread_callback = taskRunnerRunsOnCurrentThread,
            .post_task_callback = taskRunnerPostTask,
            .identifier = 0,
            .destruction_callback = null,
        };
        // Both the platform and the UI task runner are this one TaskRunner,
        // drained on the main thread. That is what makes `FlutterEngineAddView`
        // synchronous for `filo_window_create`: the engine's `RunNowOrPostTask`
        // sees the UI runner on the current thread and runs the add inline.
        // Splitting the UI runner onto another thread would break the
        // windowing contract.
        self.custom_task_runners = .{
            .struct_size = @sizeOf(c.FlutterCustomTaskRunners),
            .platform_task_runner = &self.task_runner_description,
            .render_task_runner = null,
            .thread_priority_setter = null,
            .ui_task_runner = &self.task_runner_description,
        };

        const assets_z = try allocator.dupeSentinel(u8, cfg.assets, 0);
        defer allocator.free(assets_z);
        const icu_z = try allocator.dupeSentinel(u8, cfg.icu_data, 0);
        defer allocator.free(icu_z);

        var args: c.FlutterProjectArgs = std.mem.zeroes(c.FlutterProjectArgs);
        args.struct_size = @sizeOf(c.FlutterProjectArgs);
        args.assets_path = assets_z.ptr;
        args.icu_data_path = icu_z.ptr;
        args.aot_data = self.aot_data;
        args.custom_task_runners = &self.custom_task_runners;
        args.shutdown_dart_vm_when_done = true;
        args.platform_message_callback = platform_message_callback;
        // Without this the engine paces itself with a hardcoded 60 Hz fallback,
        // no matter what the display can do.
        args.vsync_callback = vsync_callback;
        args.view_focus_change_request_callback = view_focus_change_request_callback;
        args.compositor = compositor;
        const engine_switches: []const [*:0]const u8 = if (cfg.force_impeller)
            &impeller_switches
        else
            &skia_switches;
        args.command_line_argc = @intCast(engine_switches.len);
        args.command_line_argv = @ptrCast(engine_switches.ptr);

        if (self.procs.Initialize.?(@intCast(c.FLUTTER_ENGINE_VERSION), renderer, &args, user_data, &self.handle) != 0)
            return error.EngineInitializeFailed;
        errdefer _ = self.procs.Shutdown.?(self.handle);
        if (self.procs.RunInitialized.?(self.handle) != 0)
            return error.EngineRunFailed;

        std.debug.print("fembed: engine running ({s} mode)\n", .{
            if (cfg.aot_lib != null) @as([]const u8, "AOT") else "JIT",
        });

        return self;
    }

    /// Send metrics for the implicit view, which every engine has.
    pub fn sendWindowMetrics(self: *Engine, width: usize, height: usize, dpr: f64) void {
        self.sendWindowMetricsForView(0, width, height, dpr, null);
    }

    pub fn sendWindowMetricsForView(
        self: *Engine,
        view_id: ViewId,
        width: usize,
        height: usize,
        dpr: f64,
        constraints: ?WindowConstraints,
    ) void {
        var metrics = windowMetrics(view_id, width, height, dpr, constraints);
        _ = self.procs.SendWindowMetricsEvent.?(self.handle, &metrics);
    }

    /// Add a view with `view_id`, initially `width`×`height` at `dpr`.
    ///
    /// This is asynchronous. `callback` is invoked on an engine-managed thread;
    /// it must either only touch thread-safe state or re-thread before touching
    /// Wayland or Vulkan resources. The view must not be used until the callback
    /// reports that it was added.
    ///
    /// The implicit view (0) always exists and cannot be added.
    pub fn addView(
        self: *Engine,
        view_id: ViewId,
        width: usize,
        height: usize,
        dpr: f64,
        constraints: ?WindowConstraints,
        user_data: ?*anyopaque,
        callback: AddViewCallback,
    ) !void {
        var metrics = windowMetrics(view_id, width, height, dpr, constraints);
        const info: c.FlutterAddViewInfo = .{
            .struct_size = @sizeOf(c.FlutterAddViewInfo),
            .view_id = view_id,
            .view_metrics = &metrics,
            .user_data = user_data,
            .add_view_callback = callback,
        };
        const result = self.procs.AddView.?(self.handle, &info);
        if (result != 0) return error.AddViewFailed;
    }

    /// Remove a view. The callback is required and asynchronous: the view's
    /// surface must stay alive until it reports that the view was removed.
    ///
    /// The implicit view (0) cannot be removed.
    pub fn removeView(
        self: *Engine,
        view_id: ViewId,
        user_data: ?*anyopaque,
        callback: RemoveViewCallback,
    ) !void {
        if (view_id == 0) return error.CannotRemoveImplicitView;

        const info: c.FlutterRemoveViewInfo = .{
            .struct_size = @sizeOf(c.FlutterRemoveViewInfo),
            .view_id = view_id,
            .user_data = user_data,
            .remove_view_callback = callback,
        };
        const result = self.procs.RemoveView.?(self.handle, &info);
        if (result != 0) return error.RemoveViewFailed;
    }

    /// Tell the engine that a view gained or lost platform (keyboard) focus.
    /// `direction` is only meaningful when focus moved between views.
    pub fn sendViewFocusEvent(
        self: *Engine,
        view_id: ViewId,
        state: ViewFocusState,
        direction: ViewFocusDirection,
    ) void {
        var event = viewFocusEvent(view_id, state, direction);
        const result = self.procs.SendViewFocusEvent.?(self.handle, &event);
        if (result != 0) {
            std.debug.print("fembed: SendViewFocusEvent failed: {}\n", .{result});
        }
    }

    /// Ask the engine to draw a frame. A window metrics event already makes the
    /// framework relayout and schedule one, so this is a guarantee rather than a
    /// requirement: it keeps a resize from being left unpainted if nothing else
    /// happens to ask for a frame.
    pub fn scheduleFrame(self: *Engine) void {
        _ = self.procs.ScheduleFrame.?(self.handle);
    }

    /// The engine's own monotonic clock, in nanoseconds: the timebase the vsync
    /// timestamps we hand back have to be in.
    pub fn currentTime(self: *Engine) u64 {
        return self.procs.GetCurrentTime.?();
    }

    /// Queue a baton the engine is waiting on. Called from the engine's raster
    /// thread by `vsync_callback`; `fireVsync` answers it from the main thread.
    pub fn requestVsync(self: *Engine, baton: isize) void {
        while (!self.vsync_mutex.tryLock()) std.atomic.spinLoopHint();
        self.vsync_batons.append(std.heap.c_allocator, baton) catch {
            self.vsync_mutex.unlock();
            return;
        };
        self.vsync_mutex.unlock();

        // Wake the event loop, which is also what makes it service the request.
        var one: u64 = 1;
        _ = std.os.linux.write(self.task_runner.eventfd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
    }

    pub fn hasVsyncRequests(self: *Engine) bool {
        while (!self.vsync_mutex.tryLock()) std.atomic.spinLoopHint();
        const pending = self.vsync_batons.items.len != 0;
        self.vsync_mutex.unlock();
        return pending;
    }

    /// Answer every waiting vsync request. `frame_start_ns` is when the display
    /// refreshes (a time that has just passed means "start now"), and
    /// `frame_target_ns` when the next refresh is expected.
    pub fn fireVsync(self: *Engine, frame_start_ns: u64, frame_target_ns: u64) void {
        while (!self.vsync_mutex.tryLock()) std.atomic.spinLoopHint();
        var batons = self.vsync_batons;
        self.vsync_batons = .empty;
        self.vsync_mutex.unlock();
        defer batons.deinit(std.heap.c_allocator);

        for (batons.items) |baton| {
            _ = self.procs.OnVsync.?(self.handle, baton, frame_start_ns, frame_target_ns);
        }
    }

    /// What the engine is drawing on. Without this it has no display at all, and
    /// the framework falls back for `Display.refreshRate` and the frame budget
    /// derived from it.
    pub const Display = struct {
        refresh_rate: f64,
        width: u32,
        height: u32,
        pixel_ratio: f64,
    };

    pub fn notifyDisplayStartup(self: *Engine, display: Display) void {
        const displays = [_]c.FlutterEngineDisplay{.{
            .struct_size = @sizeOf(c.FlutterEngineDisplay),
            // We only ever have the one output, so it does not need an id.
            .display_id = 0,
            .single_display = true,
            .refresh_rate = display.refresh_rate,
            .width = display.width,
            .height = display.height,
            .device_pixel_ratio = display.pixel_ratio,
        }};
        const result = self.procs.NotifyDisplayUpdate.?(
            self.handle,
            @intCast(c.kFlutterEngineDisplaysUpdateTypeStartup),
            displays[0..].ptr,
            displays.len,
        );
        if (result != 0) std.debug.print("fembed: NotifyDisplayUpdate failed: {}\n", .{result});
    }

    pub fn sendPointerEvent(self: *Engine, event: *const c.FlutterPointerEvent) void {
        _ = self.procs.SendPointerEvent.?(self.handle, event, 1);
    }

    pub fn sendKeyEvent(self: *Engine, event: *const c.FlutterKeyEvent) void {
        _ = self.procs.SendKeyEvent.?(self.handle, event, null, null);
    }

    pub fn sendPlatformMessage(self: *Engine, channel: [*:0]const u8, message: []const u8) void {
        const msg = c.FlutterPlatformMessage{
            .struct_size = @sizeOf(c.FlutterPlatformMessage),
            .channel = channel,
            .message = message.ptr,
            .message_size = message.len,
            .response_handle = null,
        };
        const result = self.procs.SendPlatformMessage.?(self.handle, &msg);
        if (result != 0) {
            std.debug.print("fembed: SendPlatformMessage failed: {}\n", .{result});
        }
    }

    /// Respond to a platform message received from the framework. Must be called
    /// for every message delivered to the platform message callback.
    pub fn sendPlatformMessageResponse(
        self: *Engine,
        handle: ?*const c.FlutterPlatformMessageResponseHandle,
        message: []const u8,
    ) void {
        if (handle == null) return;
        _ = self.procs.SendPlatformMessageResponse.?(self.handle, handle, message.ptr, message.len);
    }

    /// Queue work that must run on the thread that owns the Wayland connection
    /// and the Vulkan surfaces. Safe to call from any engine-managed thread.
    pub fn postMainTask(self: *Engine, callback: *const fn (user_data: ?*anyopaque) void, user_data: ?*anyopaque) void {
        while (!self.main_mutex.tryLock()) std.atomic.spinLoopHint();
        self.main_tasks.append(std.heap.c_allocator, .{
            .callback = callback,
            .user_data = user_data,
        }) catch {
            self.main_mutex.unlock();
            std.debug.print("fembed: could not queue main-thread task\n", .{});
            return;
        };
        self.main_mutex.unlock();

        // The same eventfd wakes the loop for both kinds of task.
        var one: u64 = 1;
        _ = std.os.linux.write(self.task_runner.eventfd, std.mem.asBytes(&one).ptr, @sizeOf(u64));
    }

    fn drainMainTasks(self: *Engine) void {
        while (!self.main_mutex.tryLock()) std.atomic.spinLoopHint();
        var tasks = self.main_tasks;
        self.main_tasks = .empty;
        self.main_mutex.unlock();
        defer tasks.deinit(std.heap.c_allocator);

        for (tasks.items) |task| task.callback(task.user_data);
    }

    /// The fd the event loop watches in order to run platform tasks on the
    /// main thread.
    pub fn getPlatformEventFd(self: *Engine) std.posix.fd_t {
        return self.task_runner.eventfd;
    }

    /// Execute all pending platform tasks on the current (main) thread.
    pub fn drainPlatformTasks(self: *Engine) void {
        const runner = &self.task_runner;
        runner.lock();
        var wake_buf: [8]u8 = undefined;
        _ = std.os.linux.read(runner.eventfd, &wake_buf, 8);
        var tasks = runner.list;
        runner.list = .empty;
        runner.mutex.unlock();

        for (tasks.items) |task| {
            _ = self.procs.RunTask.?(self.handle, &task);
        }
        tasks.deinit(std.heap.c_allocator);

        self.drainMainTasks();
    }

    pub fn deinit(self: *Engine, allocator: std.mem.Allocator) void {
        // Every baton has to be returned before the engine shuts down, or it
        // leaks the wait for it. Nothing answers them any more by this point, so
        // treat the last one as a tick that has already happened.
        const now = self.currentTime();
        self.fireVsync(now, now + self.frame_period_ns);
        // Anything the engine asks for from here on cannot be answered; it must
        // not reach a freed engine either.
        self.self_slot.*.store(null, .release);

        _ = self.procs.Shutdown.?(self.handle);
        if (self.aot_data != null) {
            _ = self.procs.CollectAOTData.?(self.aot_data);
        }
        self.lib.close();
        _ = std.os.linux.close(self.task_runner.eventfd);
        self.task_runner.list.deinit(std.heap.c_allocator);
        self.vsync_batons.deinit(std.heap.c_allocator);
        self.main_tasks.deinit(std.heap.c_allocator);
        allocator.destroy(self);
    }
};

test "window metrics are built for the requested view" {
    const metrics = windowMetrics(42, 640, 480, 1.5, null);
    try std.testing.expectEqual(@as(ViewId, 42), metrics.view_id);
    try std.testing.expectEqual(@as(usize, 640), metrics.width);
    try std.testing.expectEqual(@as(usize, 480), metrics.height);
    try std.testing.expectEqual(@as(f64, 1.5), metrics.pixel_ratio);
    try std.testing.expectEqual(false, metrics.has_constraints);
    try std.testing.expectEqual(@as(usize, @sizeOf(c.FlutterWindowMetricsEvent)), metrics.struct_size);
}

test "window metrics carry loose constraints when requested" {
    const metrics = windowMetrics(42, 320, 240, 1.5, .{
        .min_width = 1,
        .min_height = 1,
        .max_width = 16_384,
        .max_height = 16_384,
    });
    try std.testing.expectEqual(true, metrics.has_constraints);
    try std.testing.expectEqual(@as(usize, 1), metrics.min_width_constraint);
    try std.testing.expectEqual(@as(usize, 1), metrics.min_height_constraint);
    try std.testing.expectEqual(@as(usize, 16_384), metrics.max_width_constraint);
    try std.testing.expectEqual(@as(usize, 16_384), metrics.max_height_constraint);
}

test "view focus events carry the view, state and direction" {
    const event = viewFocusEvent(7, .focused, .backward);
    try std.testing.expectEqual(@as(ViewId, 7), event.view_id);
    try std.testing.expectEqual(@as(c.FlutterViewFocusState, @intCast(c.kFocused)), event.state);
    try std.testing.expectEqual(@as(c.FlutterViewFocusDirection, @intCast(c.kBackward)), event.direction);
    try std.testing.expectEqual(@as(usize, @sizeOf(c.FlutterViewFocusEvent)), event.struct_size);
}
