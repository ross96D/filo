//! Wayland host for a Flutter application using filo.
//!
//! The Flutter tool launches this executable directly as the custom device's
//! `runDebug` command. `tool/wayland.dart` writes `wayland/.filo/launch.json`
//! during the install hook; this host reads it to find the engine, ICU data,
//! assets, Dart entrypoint arguments and the optional filo switches. `FILO_*`
//! environment variables override the manifest, and a manual `zig build run`
//! without a manifest still uses the environment only.
//!
//! Command-line arguments are passed to Dart's `main(List<String> args)`, after
//! the manifest arguments. Engine switches from Flutter's custom-device
//! `${engineOptions}` are not forwarded yet.
//!
//! Extra native code and future plugins belong here: add modules to
//! `build.zig`, import them below, and initialize them before `filo.run`.

const std = @import("std");
const filo = @import("filo");

const Launch = struct {
    app_name: []const u8 = "app",
    engine: []const u8,
    icu: []const u8,
    assets: []const u8,
    aot: ?[]const u8 = null,
    dart_args: []const []const u8 = &.{},
    force_impeller: bool = false,
    vulkan_validation: bool = false,
    trace: bool = false,
    layer_only: bool = false,
    windowing_spike: bool = false,
};

const launch_paths = [_][]const u8{
    "wayland/.filo/launch.json",
    ".filo/launch.json",
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    const config = try loadConfig(init, arena, argv);
    const runtime = try filo.Runtime.init(init.gpa, init.io, config);
    defer runtime.deinit();
    try runtime.run();
}

fn loadConfig(
    init: std.process.Init,
    arena: std.mem.Allocator,
    argv: []const []const u8,
) !filo.Config {
    const launch = try loadLaunch(init, arena) orelse {
        var config = try filo.Config.fromEnv(init.environ_map);
        config.dart_entrypoint_args = if (argv.len > 1) argv[1..] else argv[0..0];
        return config;
    };

    const env = init.environ_map;
    const extra_args = if (argv.len > 1) argv[1..] else argv[0..0];
    const dart_args = if (env.get("FILO_DART_ENTRYPOINT_ARGS")) |value|
        try appendArgs(arena, try splitArgs(arena, value), extra_args)
    else
        try appendArgs(arena, launch.dart_args, extra_args);
    const aot: ?[]const u8 = if (env.get("FILO_AOT_LIB")) |value| value else launch.aot;

    return .{
        .engine_lib = env.get("FILO_ENGINE_LIB") orelse launch.engine,
        .icu_data = env.get("FILO_ICU_DATA") orelse launch.icu,
        .assets = env.get("FILO_ASSETS") orelse launch.assets,
        .aot_lib = aot,
        .force_impeller = envFlag(env, "FORCE_IMPELLER", launch.force_impeller),
        .vulkan_validation = envFlag(env, "FILO_VULKAN_VALIDATION", launch.vulkan_validation),
        .trace = envFlag(env, "FILO_TRACE", launch.trace),
        .bootstrap_layer = envFlag(env, "FILO_LAYER_ONLY", launch.layer_only),
        .windowing_spike = envFlag(env, "FILO_WINDOWING_SPIKE", launch.windowing_spike),
        .dart_entrypoint_args = dart_args,
    };
}

fn loadLaunch(init: std.process.Init, arena: std.mem.Allocator) !?Launch {
    for (launch_paths) |path| {
        const text = std.Io.Dir.cwd().readFileAlloc(
            init.io,
            path,
            arena,
            .limited(1 << 20),
        ) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        return std.json.parseFromSliceLeaky(
            Launch,
            arena,
            text,
            .{ .ignore_unknown_fields = true },
        ) catch |err| {
            std.debug.print("filo: invalid launch manifest {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
    }
    return null;
}

fn envFlag(map: *const std.process.Environ.Map, name: []const u8, fallback: bool) bool {
    const value = map.get(name) orelse return fallback;
    return value.len != 0;
}

fn splitArgs(arena: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    var iterator = std.mem.splitScalar(u8, value, '\n');
    while (iterator.next()) |line| {
        if (line.len == 0) continue;
        try list.append(arena, line);
    }
    return try list.toOwnedSlice(arena);
}

fn appendArgs(
    arena: std.mem.Allocator,
    base: []const []const u8,
    extra: []const []const u8,
) ![]const []const u8 {
    if (extra.len == 0) return base;
    const result = try arena.alloc([]const u8, base.len + extra.len);
    @memcpy(result[0..base.len], base);
    @memcpy(result[base.len..], extra);
    return result;
}
