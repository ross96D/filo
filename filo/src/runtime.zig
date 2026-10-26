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
    io: std.Io,

    /// The caller's config with every string copied into storage owned here.
    /// Components that keep the config (or parts of it) outlive the caller's
    /// buffers.
    config: manifest.Config = undefined,
    engine_lib: ?[:0]u8 = null,
    icu_data: ?[:0]u8 = null,
    assets: ?[:0]u8 = null,
    aot_lib: ?[:0]u8 = null,

    loop: ev.Loop = undefined,
    loop_ready: bool = false,
    conn: ?*connection.Connection = null,
    /// The bootstrap toplevel, until the first window controller adopts view 0.
    first_win: ?*window.Window = null,
    vk: vulkan.Context = undefined,
    vk_ready: bool = false,

    app: app_mod.App = undefined,
    app_ready: bool = false,
    windowing_installed: bool = false,
    eng: ?*engine.Engine = null,

    ti: text_input.TextInput = undefined,
    ti_ready: bool = false,
    inp: input.Input = undefined,
    inp_ready: bool = false,
    ph: platform_handler.PlatformHandler = undefined,
    ph_ready: bool = false,
    wm: window_manager.WindowManager = undefined,
    mc: mouse_cursor.MouseCursor = undefined,

    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ran: bool = false,

    /// Build the whole embedder: connection, loop, Vulkan, engine and handlers.
    /// No window is created here; the first windowing request creates the
    /// implicit view's native surface. Every failure unwinds through `deinit`.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: manifest.Config,
    ) !*Runtime {
        if (instance_active.swap(true, .acq_rel)) return error.AlreadyInitialized;
        errdefer instance_active.store(false, .release);

        const self = try allocator.create(Runtime);
        errdefer self.deinit();
        self.* = .{ .allocator = allocator, .io = io };

        // Copy the config so callers may keep using their own buffers after
        // `init` returns.
        self.engine_lib = try allocator.dupeSentinel(u8, config.engine_lib, 0);
        self.icu_data = try allocator.dupeSentinel(u8, config.icu_data, 0);
        self.assets = try allocator.dupeSentinel(u8, config.assets, 0);
        if (config.aot_lib) |aot| self.aot_lib = try allocator.dupeSentinel(u8, aot, 0);
        self.config = .{
            .engine_lib = self.engine_lib.?,
            .icu_data = self.icu_data.?,
            .assets = self.assets.?,
            .aot_lib = if (self.aot_lib) |aot| aot else null,
            .force_impeller = config.force_impeller,
            .vulkan_validation = config.vulkan_validation,
            .trace = config.trace,
            .layer_only = config.layer_only,
            .windowing_spike = config.windowing_spike,
            .engine_args = config.engine_args,
        };

        const conn = try connection.Connection.connect(allocator);
        self.conn = conn;

        if (config.layer_only) {
            // Bootstrap the implicit view with the configured layer surface.
            // The first layer controller adopts it; the surface exists before
            // the engine, so its first frame follows the same startup path as
            // a regular window.
            var state = std.mem.zeroes(windowing.LayerSurface);
            const boot = config.layer_bootstrap;
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
            const first_win = try conn.createLayer(.{
                .state = state,
                .output = null,
                .namespace = boot.namespace.ptr,
                .width = boot.width,
                .height = boot.height,
            });
            self.first_win = first_win;
            try conn.waitReady(first_win);
        } else {
            // Bootstrap the implicit view's toplevel before the engine starts.
            // The first regular window adopts it; creating that surface later,
            // from a Dart callback, leaves the toplevel's first frame
            // unpainted.
            const first_win = try conn.createWindow();
            self.first_win = first_win;
            try conn.waitReady(first_win);
        }

        // The one loop in the program. Everything below registers a descriptor
        // or a timer with it and does its work from a callback.
        try self.loop.init(.{ .allocator = allocator });
        self.loop_ready = true;

        self.vk = try vulkan.Context.init(allocator, io, .{
            .validation = config.vulkan_validation,
            .trace = config.trace,
        });
        self.vk_ready = true;

        self.app = .{
            .ctx = undefined,
            .vk = &self.vk,
            .channels = platform_channel.Registry.init(),
            .windowing_spike = config.windowing_spike,
        };
        self.app_ready = true;

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
            self.config,
            &renderer,
            &self.app.compositor,
            &self.app,
            &self.app.engine,
            app_mod.platformMessageCallback,
            app_mod.onPreEngineRestart,
            app_mod.vsyncCallback,
            app_mod.viewFocusChangeRequestCallback,
        );
        self.eng = eng;
        self.app.channels.eng = eng;

        // The engine parses the switches during `Engine.init`; do not keep the
        // caller's borrowed argv pointers around after that.
        self.config.engine_args = &.{};

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
        self.windowing_installed = true;

        var first_view: ?*app_mod.View = null;
        if (self.first_win) |first_win| {
            first_view = try self.app.adoptView(0, first_win);
            first_view.?.added = true;
            self.first_win = null;
        }

        self.ti = text_input.TextInput.init(allocator, eng);
        self.ti_ready = true;
        self.app.channels.text_input = &self.ti;

        self.inp = try input.Input.init(eng, &self.ti);
        self.inp_ready = true;
        self.inp.setViewResolver(&self.app, app_mod.viewForSurface);
        self.inp.setScaleResolver(&self.app, app_mod.viewScaleForSurface);
        try conn.bindSeat(&self.app.ctx, &self.inp);

        self.ph = platform_handler.PlatformHandler.init(
            allocator,
            eng,
            conn.clipboard.?,
            &self.loop,
        );
        self.ph_ready = true;
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

        const pixel_ratio: f64 = if (first_view) |view|
            view.win.pixel_ratio
        else
            @floatFromInt(conn.display_scale);
        if (first_view) |view| {
            eng.sendWindowMetricsForView(
                0,
                view.win.physicalWidth(),
                view.win.physicalHeight(),
                view.win.pixel_ratio,
                null,
            );
        }
        // Without this the engine has no display at all and falls back for the
        // refresh rate it derives its frame budget from.
        if (conn.refresh_mhz != 0) {
            eng.notifyDisplayStartup(.{
                .refresh_rate = @as(f64, @floatFromInt(conn.refresh_mhz)) / 1000.0,
                .width = conn.display_width,
                .height = conn.display_height,
                .pixel_ratio = pixel_ratio,
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

    /// Tear the embedder down and free the runtime. The order mirrors the
    /// defers the old `main` relied on: handlers, engine, windows, Vulkan, the
    /// loop, then the Wayland connection.
    pub fn deinit(self: *Runtime) void {
        if (self.ph_ready) {
            self.ph.deinit();
            self.ph_ready = false;
        }
        if (self.inp_ready) {
            self.inp.deinit();
            self.inp_ready = false;
        }
        if (self.ti_ready) {
            self.ti.deinit();
            self.ti_ready = false;
        }
        if (self.eng) |eng| {
            eng.deinit(self.allocator);
            self.eng = null;
        }
        if (self.windowing_installed) {
            windowing.uninstall();
            self.windowing_installed = false;
        }
        if (self.app_ready) {
            self.app.deinitViews();
            self.app.channels.deinit();
            self.app_ready = false;
        }
        if (self.vk_ready) {
            self.vk.deinit();
            self.vk_ready = false;
        }
        if (self.loop_ready) {
            self.loop.deinit();
            self.loop_ready = false;
        }
        if (self.first_win) |win| {
            win.destroy(self.allocator);
            self.first_win = null;
        }
        if (self.conn) |conn| {
            conn.deinit();
            self.conn = null;
        }

        if (self.aot_lib) |value| {
            self.allocator.free(value);
            self.aot_lib = null;
        }
        if (self.assets) |value| {
            self.allocator.free(value);
            self.assets = null;
        }
        if (self.icu_data) |value| {
            self.allocator.free(value);
            self.icu_data = null;
        }
        if (self.engine_lib) |value| {
            self.allocator.free(value);
            self.engine_lib = null;
        }

        const allocator = self.allocator;
        instance_active.store(false, .release);
        allocator.destroy(self);
    }
};

/// Convenience for a host whose lifetime is exactly one embedder run.
pub fn run(allocator: std.mem.Allocator, io: std.Io, config: manifest.Config) !void {
    const runtime = try Runtime.init(allocator, io, config);
    defer runtime.deinit();
    try runtime.run();
}
