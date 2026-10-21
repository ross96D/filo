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
        self.custom_task_runners = .{
            .struct_size = @sizeOf(c.FlutterCustomTaskRunners),
            .platform_task_runner = &self.task_runner_description,
            .render_task_runner = null,
            .thread_priority_setter = null,
            .ui_task_runner = null,
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

    pub fn sendWindowMetrics(self: *Engine, width: usize, height: usize, dpr: f64) void {
        var metrics: c.FlutterWindowMetricsEvent = .{
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
            .view_id = 0,
            .has_constraints = false,
            .min_width_constraint = 0,
            .min_height_constraint = 0,
            .max_width_constraint = 0,
            .max_height_constraint = 0,
        };
        _ = self.procs.SendWindowMetricsEvent.?(self.handle, &metrics);
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
        allocator.destroy(self);
    }
};
