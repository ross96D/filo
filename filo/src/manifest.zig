const std = @import("std");

pub const Config = struct {
    engine_lib: []const u8,
    icu_data: []const u8,
    assets: []const u8,
    aot_lib: ?[]const u8,
    /// Use Impeller instead of the default Skia renderer.
    force_impeller: bool,
};

pub fn load(map: *const std.process.Environ.Map) !Config {
    return .{
        .engine_lib = try required(map, "FILO_ENGINE_LIB"),
        .icu_data = try required(map, "FILO_ICU_DATA"),
        .assets = try required(map, "FILO_ASSETS"),
        .aot_lib = map.get("FILO_AOT_LIB"),
        .force_impeller = map.get("FORCE_IMPELLER") != null,
    };
}

fn required(map: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    return map.get(name) orelse {
        std.debug.print("filo: required environment variable {s} is not set\n", .{name});
        return error.MissingEnvironmentVariable;
    };
}
