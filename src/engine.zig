const std = @import("std");

const manifest = @import("manifest.zig");

const c = @import("flutter");

const GetProcAddressesFn = *const fn (*c.FlutterEngineProcTable) callconv(.c) c.FlutterEngineResult;

pub const Engine = struct {
    allocator: std.mem.Allocator,
    lib: std.DynLib,
    procs: c.FlutterEngineProcTable,
    handle: c.FlutterEngine,
    aot_data: c.FlutterEngineAOTData,

    pub fn init(allocator: std.mem.Allocator, cfg: manifest.Config) !Engine {
        var lib = try std.DynLib.open(cfg.engine_lib);
        errdefer lib.close();

        const get_proc_addresses: GetProcAddressesFn = lib.lookup(
            GetProcAddressesFn,
            "FlutterEngineGetProcAddresses",
        ) orelse return error.SymbolNotFound;

        var procs: c.FlutterEngineProcTable = std.mem.zeroes(c.FlutterEngineProcTable);
        procs.struct_size = @sizeOf(c.FlutterEngineProcTable);
        if (get_proc_addresses(&procs) != c.kSuccess) return error.ProcTableInitFailed;

        var aot_data: c.FlutterEngineAOTData = null;
        if (cfg.aot_lib) |aot_lib_path| {
            const aot_lib_z = try allocator.dupeSentinel(u8, aot_lib_path, 0);
            defer allocator.free(aot_lib_z);
            var source: c.FlutterEngineAOTDataSource = .{
                .type = c.kFlutterEngineAOTDataSourceTypeElfPath,
                .unnamed_0 = .{ .elf_path = aot_lib_z.ptr },
            };
            if (procs.CreateAOTData.?(&source, &aot_data) != 0)
                return error.CreateAOTDataFailed;
        }

        const assets_z = try allocator.dupeSentinel(u8, cfg.assets, 0);
        defer allocator.free(assets_z);
        const icu_z = try allocator.dupeSentinel(u8, cfg.icu_data, 0);
        defer allocator.free(icu_z);

        var args: c.FlutterProjectArgs = std.mem.zeroes(c.FlutterProjectArgs);
        args.struct_size = @sizeOf(c.FlutterProjectArgs);
        args.assets_path = assets_z.ptr;
        args.icu_data_path = icu_z.ptr;
        args.aot_data = aot_data;
        args.shutdown_dart_vm_when_done = true;

        var renderer: c.FlutterRendererConfig = undefined;
        renderer.type = c.kSoftware;
        renderer.unnamed_0.software = .{
            .struct_size = @sizeOf(c.FlutterSoftwareRendererConfig),
            .surface_present_callback = softwarePresent,
        };

        var engine: c.FlutterEngine = null;
        if (procs.Initialize.?(@intCast(c.FLUTTER_ENGINE_VERSION), &renderer, &args, null, &engine) != 0)
            return error.EngineInitializeFailed;
        errdefer _ = procs.Shutdown.?(engine);
        if (procs.RunInitialized.?(engine) != 0)
            return error.EngineRunFailed;

        std.debug.print("fembed: engine running ({s} mode)\n", .{
            if (cfg.aot_lib != null) @as([]const u8, "AOT") else "JIT",
        });

        return .{
            .allocator = allocator,
            .lib = lib,
            .procs = procs,
            .handle = engine,
            .aot_data = aot_data,
        };
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

    pub fn deinit(self: *Engine) void {
        _ = self.procs.Shutdown.?(self.handle);
        if (self.aot_data != null) {
            _ = self.procs.CollectAOTData.?(self.aot_data);
        }
        self.lib.close();
    }

    fn softwarePresent(
        user_data: ?*anyopaque,
        allocation: ?*const anyopaque,
        row_bytes: usize,
        height: usize,
    ) callconv(.c) bool {
        _ = user_data;
        _ = allocation;
        std.debug.print("fembed: software frame {}x{} row_bytes={}\n", .{
            row_bytes / 4,
            height,
            row_bytes,
        });
        return true;
    }
};
