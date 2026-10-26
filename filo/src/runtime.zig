//! The embedder's lifecycle: everything `main` used to do, but owned by a
//! heap-allocated `Runtime` so a host executable can start and stop it.
//!
//! A process has one `Runtime` at a time. `App`, the handlers and the loop all
//! hand their addresses to the engine, to Dart through the `filo_window_*` C
//! ABI, and to each other, so the `Runtime` must never be copied or moved.

const std = @import("std");

const zio = @import("zio");
const ev = zio.ev;

const app_mod = @import("app.zig");
const c = @import("flutter");
const connection = @import("wayland/connection.zig");
const window = @import("wayland/window.zig");
const frame_clock = @import("wayland/frame_clock.zig");
const engine = @import("engine.zig");
const manifest = @import("manifest.zig");
const vulkan = @import("vulkan.zig");
const input = @import("input.zig");
const text_input = @import("flutter/text_input.zig");
const platform_handler = @import("flutter/platform_handler.zig");
const window_manager = @import("flutter/window_manager.zig");
const mouse_cursor = @import("flutter/mouse_cursor.zig");
const platform_channel = @import("flutter/platform_channel.zig");
const windowing = @import("windowing.zig");

/// Whether a runtime already owns the process-wide embedder state.
var instance_active = std.atomic.Value(bool).init(false);

pub const Runtime = struct {
    allocator: std.mem.Allocator,

    /// The caller's config strings, copied into storage owned here.
    engine_lib: [:0]u8 = undefined,
    icu_data: [:0]u8 = undefined,
    assets: [:0]u8 = undefined,
    aot_lib: ?[:0]u8 = null,

    loop: ev.Loop = undefined,
    vk: vulkan.Context = undefined,

    app: app_mod.App = undefined,

    ti: text_input.TextInput = undefined,
    inp: input.Input = undefined,
    ph: platform_handler.PlatformHandler = undefined,
    wm: window_manager.WindowManager = undefined,
    mc: mouse_cursor.MouseCursor = undefined,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ran: bool = false,

    /// Build the whole embedder: config copies, connection, loop, Vulkan,
    /// engine and handlers. The bootstrap window is created before the engine;
    /// the first windowing request adopts it as the implicit view. Every failure
    /// here unwinds locally, so `deinit` only ever sees a fully built runtime.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: manifest.Config,
    ) !*Runtime {
        if (instance_active.swap(true, .acq_rel)) return error.AlreadyInitialized;
        errdefer instance_active.store(false, .release);

        // Copy the config paths before callers can free their buffers. The
        // engine consumes them during init; the copies stay owned by the
        // runtime.
        const engine_lib = try allocator.dupeSentinel(u8, config.engine_lib, 0);
        errdefer allocator.free(engine_lib);
        const icu_data = try allocator.dupeSentinel(u8, config.icu_data, 0);
        errdefer allocator.free(icu_data);
        const assets = try allocator.dupeSentinel(u8, config.assets, 0);
        errdefer allocator.free(assets);
        const aot_lib: ?[:0]u8 = if (config.aot_lib) |aot|
            try allocator.dupeSentinel(u8, aot, 0)
        else
            null;
        errdefer if (aot_lib) |aot| allocator.free(aot);

        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .engine_lib = engine_lib,
            .icu_data = icu_data,
            .assets = assets,
            .aot_lib = aot_lib,
        };

        const engine_config = manifest.Config{
            .engine_lib = engine_lib,
            .icu_data = icu_data,
            .assets = assets,
            .aot_lib = aot_lib,
            .force_impeller = config.force_impeller,
            .vulkan_validation = config.vulkan_validation,
            .trace = config.trace,
            .bootstrap_layer = config.bootstrap_layer,
            .windowing_spike = config.windowing_spike,
            .engine_args = config.engine_args,
        };

        const conn = try connection.Connection.connect(allocator);
        errdefer conn.deinit();

        // The bootstrap window must exist before the engine so its first frame
        // follows the same startup path as a regular window. It stays local:
        // once adopted it is owned by the implicit view.
        var boot_win: ?*window.Window = if (config.bootstrap_layer) blk: {
            // Bootstrap the implicit view with the configured layer surface.
            // The first layer controller adopts it.
            var state = std.mem.zeroes(windowing.LayerSurface);
            const boot = config.bootstrap_layer_surface;
            state.layer = boot.layer;
            state.anchor = boot.anchor;
            state.exclusive_zone = boot.exclusive_zone;
            state.keyboard_interactivity = boot.keyboard_interactivity;
            state.margin_top = boot.margin_top;
            state.margin_right = boot.margin_right;
            state.margin_bottom = boot.margin_bottom;
            state.margin_left = boot.margin_left;
            state.output = -1;
            state.accepts_input = if (boot.accepts_input) 1 else 0;
            break :blk try conn.createLayer(.{
                .state = state,
                .output = null,
                .namespace = boot.namespace.ptr,
                .width = boot.width,
                .height = boot.height,
            });
        } else try conn.createWindow();
        errdefer if (boot_win) |win| win.destroy(allocator);
        try conn.waitReady(boot_win.?);

        // The one loop in the program. Everything below registers a descriptor
        // or a timer with it and does its work from a callback.
        try self.loop.init(.{ .allocator = allocator });
        errdefer self.loop.deinit();

        self.vk = try vulkan.Context.init(allocator, io, .{
            .validation = config.vulkan_validation,
            .trace = config.trace,
        });
        errdefer self.vk.deinit();

        self.app = .{
            .ctx = undefined,
            .vk = &self.vk,
            .channels = platform_channel.Registry.init(),
            .windowing_spike = config.windowing_spike,
        };
        errdefer {
            self.app.deinitViews();
            self.app.channels.deinit();
        }

        const renderer = app_mod.rendererConfig(&self.vk);

        // Impeller's Vulkan backend cannot render into compositor backing
        // stores. FORCE_IMPELLER still turns it on, which is expected to fail:
        // this embedder has no direct-to-swapchain path any more.
        self.app.compositor = .{
            .struct_size = @sizeOf(c.FlutterCompositor),
            .user_data = &self.app,
            .create_backing_store_callback = app_mod.createBackingStore,
            .collect_backing_store_callback = app_mod.collectBackingStore,
            .present_layers_callback = null,
            .avoid_backing_store_cache = false,
            .present_view_callback = app_mod.presentViewCallback,
        };

        const eng = try engine.Engine.init(
            allocator,
            engine_config,
            &renderer,
            &self.app.compositor,
            &self.app,
            &self.app.engine,
            app_mod.platformMessageCallback,
            app_mod.onPreEngineRestart,
            app_mod.vsyncCallback,
            app_mod.viewFocusChangeRequestCallback,
        );
        var windowing_installed = false;
        errdefer {
            eng.deinit(allocator);
            if (windowing_installed) windowing.uninstall();
        }
        self.app.channels.eng = eng;

        // The globals are only complete once the engine exists.
        self.app.ctx = .{
            .allocator = allocator,
            .loop = &self.loop,
            .conn = conn,
            .eng = eng,
        };
        self.app.frame_clock = try frame_clock.FrameClock.init(
            &self.app.ctx,
            conn.frame_period_ns,
        );
        self.app.ctx_ready = true;

        // The C ABI Dart binds to (`filo_window_*`). `app` lives in this
        // heap-allocated struct, so the pointers handed out here stay valid.
        windowing.install(self.app.toHost());
        windowing_installed = true;

        const first_view = try self.app.adoptView(0, boot_win.?);
        first_view.engine_state = .added;
        boot_win = null;

        self.ti = text_input.TextInput.init(allocator, eng);
        errdefer self.ti.deinit();
        self.app.channels.text_input = &self.ti;

        self.inp = try input.Input.init(eng, &self.ti);
        errdefer self.inp.deinit();
        self.inp.setViewResolver(&self.app, app_mod.viewForSurface);
        self.inp.setScaleResolver(&self.app, app_mod.viewScaleForSurface);
        try conn.bindSeat(&self.app.ctx, &self.inp);

        self.ph = platform_handler.PlatformHandler.init(
            allocator,
            eng,
            conn.clipboard.?,
            &self.loop,
        );
        errdefer self.ph.deinit();
        self.ph.attach();
        self.app.channels.platform = &self.ph;

        self.wm = .{
            .eng = eng,
            .user_data = &self.app,
            .create = app_mod.onCreateWindow,
            .close = app_mod.onCloseWindow,
        };
        self.app.channels.windows = &self.wm;

        self.mc = .{
            .eng = eng,
            .user_data = &self.app,
            .set = app_mod.onSetCursor,
        };
        self.app.channels.mouse_cursor = &self.mc;

        eng.sendWindowMetricsForView(
            0,
            first_view.win.physicalWidth(),
            first_view.win.physicalHeight(),
            first_view.win.pixel_ratio,
            null,
        );
        // Without this the engine has no display at all and falls back for the
        // refresh rate it derives its frame budget from.
        if (conn.refresh_mhz != 0) {
            eng.notifyDisplayStartup(.{
                .refresh_rate = @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
                .width = conn.display_width,
                .height = conn.display_height,
                .pixel_ratio = first_view.win.pixel_ratio,
            });
            std.debug.print("filo: display {}x{} at {d:.3} Hz\n", .{
                conn.display_width,
                conn.display_height,
                @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
            });
        }

        // A way to exercise multi-view rendering without clicking anything is
        // intentionally left to the Dart app: creating a view from the embedder
        // before the first app window would race the engine's first frame.

        return self;
    }

    /// Run the embedder's event loop. This blocks until the loop stops, which
    /// can be caused by the framework asking to quit, by a `stop` request, or
    /// by the last view going away. `run` can only be called once.
    pub fn run(self: *Runtime) !void {
        if (self.ran) return error.AlreadyRun;
        self.ran = true;
        self.running.store(true, .release);
        defer self.running.store(false, .release);

        try app_mod.runLoop(&self.app);
    }

    /// Stop a running loop. Safe to call from another thread.
    pub fn stop(self: *Runtime) void {
        if (!self.running.load(.acquire)) return;
        app_mod.requestStop(&self.app);
    }

    /// Tear down a fully initialized runtime. `init` unwinds its own partial
    /// failures, so every resource here is known to exist.
    pub fn deinit(self: *Runtime) void {
        self.ph.deinit();
        self.inp.deinit();
        self.ti.deinit();

        const eng = self.app.ctx.eng;
        eng.deinit(self.allocator);
        windowing.uninstall();

        self.app.deinitViews();
        self.app.channels.deinit();
        self.vk.deinit();
        self.loop.deinit();
        self.app.ctx.conn.deinit();

        const allocator = self.allocator;
        if (self.aot_lib) |value| allocator.free(value);
        allocator.free(self.assets);
        allocator.free(self.icu_data);
        allocator.free(self.engine_lib);

        instance_active.store(false, .release);
        allocator.destroy(self);
    }

    pub fn view_by_id(self: *const Runtime, id: engine.ViewId) ?*app_mod.View {
        return self.app.views_by_id.get(id);
    }
};
