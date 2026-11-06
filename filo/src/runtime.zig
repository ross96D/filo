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
const mouse_cursor = @import("flutter/mouse_cursor.zig");
const platform_channel = @import("flutter/platform_channel.zig");
const windowing = @import("windowing.zig");

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    /// The caller's config strings, copied into storage owned here.
    engine_lib: [:0]u8 = undefined,
    icu_data: [:0]u8 = undefined,
    assets: [:0]u8 = undefined,
    aot_lib: ?[:0]u8 = null,

    /// Where the embedder publishes the debug VM service URI, if it has one.
    /// The screenshot tool reads this file to ask the engine for a PNG.
    vm_service_info: ?[]u8 = null,

    loop: ev.Loop = undefined,
    vk: vulkan.Context = undefined,

    app: app_mod.App = undefined,

    ti: text_input.TextInput = undefined,
    inp: input.Input = undefined,
    ph: platform_handler.PlatformHandler = undefined,
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

        // The screenshot tool talks to the debug VM service over loopback. Pick
        // the port ourselves so the embedder can publish a URI immediately; the
        // engine only writes `--write-service-info` when the VM starts its own
        // service, which is not how the embedder starts it. Release (AOT)
        // builds have no VM service and publish nothing.
        var vm_service_port: ?u16 = null;
        var vm_service_info: ?[]u8 = null;
        if (aot_lib == null and !hasEngineFlag(config.engine_args, "--disable-vm-service")) {
            vm_service_port = allocateLoopbackPort(io) catch |err| blk: {
                std.debug.print("filo: cannot reserve a VM service port: {}\n", .{err});
                break :blk null;
            };
            if (vm_service_port) |port| {
                vm_service_info = try publishVmServiceInfo(allocator, io, port);
                // Without the file the tool cannot find the app; leave the
                // engine with its normal port selection instead.
                if (vm_service_info == null) vm_service_port = null;
            }
        }
        errdefer if (vm_service_info) |path| {
            std.Io.Dir.deleteFileAbsolute(io, path) catch {};
            allocator.free(path);
        };

        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .engine_lib = engine_lib,
            .icu_data = icu_data,
            .assets = assets,
            .aot_lib = aot_lib,
            .vm_service_info = vm_service_info,
        };

        // The VM service switches are appended after the host's engine args,
        // so they win if the host also set a port or host. They are only for
        // this init call; Engine.init copies what it needs.
        var args_arena = std.heap.ArenaAllocator.init(allocator);
        defer args_arena.deinit();
        const args_alloc = args_arena.allocator();
        var engine_args: std.ArrayListUnmanaged([]const u8) = .empty;
        try engine_args.appendSlice(args_alloc, config.engine_args);
        if (vm_service_port) |port| {
            try engine_args.append(
                args_alloc,
                try std.fmt.allocPrint(args_alloc, "--vm-service-port={d}", .{port}),
            );
            try engine_args.append(args_alloc, "--vm-service-host=127.0.0.1");
            try engine_args.append(args_alloc, "--disable-service-auth-codes");
        }

        const engine_config = manifest.Config{
            .engine_lib = engine_lib,
            .icu_data = icu_data,
            .assets = assets,
            .aot_lib = aot_lib,
            .force_impeller = config.force_impeller,
            .vulkan_validation = config.vulkan_validation,
            .trace = config.trace,
            .bootstrap_layer = config.bootstrap_layer,
            .engine_args = engine_args.items,
            .dart_entrypoint_args = config.dart_entrypoint_args,
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
            .engine = null,
            .channels = platform_channel.Registry.init(),
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
            app_mod.platformMessageCallback,
            app_mod.onPreEngineRestart,
            app_mod.vsyncCallback,
            app_mod.viewFocusChangeRequestCallback,
        );
        self.app.engine = eng;
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
        self.app.engine = null;
        windowing.uninstall();

        // The embedder published this while the engine was alive; it is stale
        // once the engine is gone, and a reader must not mistake it for a
        // running app.
        if (self.vm_service_info) |path| {
            std.Io.Dir.deleteFileAbsolute(self.io, path) catch {};
            self.allocator.free(path);
        }

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

        allocator.destroy(self);
    }

    pub fn view_by_id(self: *const Runtime, id: engine.ViewId) ?*app_mod.View {
        return self.app.views_by_id.get(id);
    }
};

/// Pick the file the embedder publishes its VM service URI in.
///
/// The file lives under `$XDG_RUNTIME_DIR/filo` and is named after the
/// executable and process, so several running apps (and several instances of
/// one app) do not collide. Returning null simply disables the screenshot tool;
/// it never prevents the app from starting.
fn resolveVmServiceInfo(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    const runtime_dir_ptr = std.c.getenv("XDG_RUNTIME_DIR") orelse return null;
    const runtime_dir = std.mem.span(runtime_dir_ptr);
    if (runtime_dir.len == 0) return null;

    const exe = std.process.executablePathAlloc(io, allocator) catch |err| {
        std.debug.print(
            "filo: cannot resolve the executable path for VM service info: {}\n",
            .{err},
        );
        return null;
    };
    defer allocator.free(exe);

    const dir = try std.fs.path.join(allocator, &.{ runtime_dir, "filo" });
    defer allocator.free(dir);
    std.Io.Dir.createDirPath(.cwd(), io, dir) catch |err| {
        std.debug.print(
            "filo: cannot create VM service info directory {s}: {}\n",
            .{ dir, err },
        );
        return null;
    };

    return try std.fmt.allocPrint(allocator, "{s}/{s}-{d}.json", .{
        dir,
        std.fs.path.basename(exe),
        std.os.linux.getpid(),
    });
}

/// Reserve a loopback port for the debug VM service. The engine binds the same
/// port after this listener closes; the short race is preferable to not knowing
/// which port the engine picked.
fn allocateLoopbackPort(io: std.Io) !u16 {
    var address: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try address.listen(io, .{});
    defer server.deinit(io);
    return server.socket.address.getPort();
}

/// Write the service URI the screenshot tool connects to. The engine's service
/// is started with `--disable-service-auth-codes`, so the URI has no token.
fn publishVmServiceInfo(
    allocator: std.mem.Allocator,
    io: std.Io,
    port: u16,
) !?[]u8 {
    const path = try resolveVmServiceInfo(allocator, io) orelse return null;

    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"uri\":\"http://127.0.0.1:{d}/\"}}", .{port}) catch unreachable;
    std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = json }) catch |err| {
        std.debug.print("filo: cannot write VM service info {s}: {}\n", .{ path, err });
        allocator.free(path);
        return null;
    };
    return path;
}

fn hasEngineFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
        if (arg.len > flag.len and
            std.mem.startsWith(u8, arg, flag) and
            arg[flag.len] == '=') return true;
    }
    return false;
}
