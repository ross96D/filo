//! Wayland host for a Flutter application using filo.
//!
//! The host expects this layout next to the executable:
//!
//!   <app_name>
//!   lib/libflutter_engine.so
//!   lib/libapp.so          (release only)
//!   data/icudtl.dat
//!   data/flutter_assets/
//!
//! `FILO_ENGINE_LIB`, `FILO_ICU_DATA`, `FILO_ASSETS` and `FILO_AOT_LIB`
//! override the derived paths. `FILO_DART_ENTRYPOINT_ARGS` adds arguments for
//! Dart's `main(List<String> args)` before the command-line arguments.
//!
//! Extra native code and future plugins belong here: add modules to
//! `build.zig`, import them below, and initialize them before `filo.run`.

const std = @import("std");
const filo = @import("filo");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    const argv = try init.minimal.args.toSlice(arena.allocator());

    const config = try loadConfig(init, arena.allocator(), argv);
    const runtime = try filo.Runtime.init(init.gpa, init.io, config);
    arena.deinit();
    defer runtime.deinit();
    try runtime.run();
}

fn loadConfig(
    init: std.process.Init,
    arena: std.mem.Allocator,
    argv: []const []const u8,
) !filo.Config {
    const env = init.environ_map;
    const root = try std.process.executableDirPathAlloc(init.io, arena);
    const extra_args = if (argv.len > 1) argv[1..] else argv[0..0];
    const dart_args = if (env.get("FILO_DART_ENTRYPOINT_ARGS")) |value|
        try appendArgs(arena, try splitArgs(arena, value), extra_args)
    else
        extra_args;

    return .{
        .engine_lib = env.get("FILO_ENGINE_LIB") orelse
            try join(arena, root, "lib/libflutter_engine.so"),
        .icu_data = env.get("FILO_ICU_DATA") orelse
            try join(arena, root, "data/icudtl.dat"),
        .assets = env.get("FILO_ASSETS") orelse
            try join(arena, root, "data/flutter_assets"),
        .aot_lib = try optionalPath(init.io, arena, env.get("FILO_AOT_LIB"), root, "lib/libapp.so"),
        .force_impeller = env.get("FORCE_IMPELLER") != null,
        .vulkan_validation = env.get("FILO_VULKAN_VALIDATION") != null,
        .trace = env.get("FILO_TRACE") != null,
        .bootstrap_layer = env.get("FILO_LAYER_ONLY") != null,
        .dart_entrypoint_args = dart_args,
    };
}

fn join(arena: std.mem.Allocator, root: []const u8, sub_path: []const u8) ![]const u8 {
    return std.fs.path.join(arena, &.{ root, sub_path });
}

fn optionalPath(
    io: std.Io,
    arena: std.mem.Allocator,
    override: ?[]const u8,
    root: []const u8,
    sub_path: []const u8,
) !?[]const u8 {
    if (override) |path| return path;
    const path = try join(arena, root, sub_path);
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return null;
    return path;
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
