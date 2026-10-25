const std = @import("std");

/// Everything the embedder needs to start, passed by the host. The strings may
/// be borrowed for the duration of `Runtime.init`; the runtime copies them.
pub const Config = struct {
    engine_lib: []const u8,
    icu_data: []const u8,
    assets: []const u8,
    aot_lib: ?[]const u8 = null,
    /// Use Impeller instead of the default Skia renderer.
    force_impeller: bool = false,
    /// Enable the Vulkan validation layer when it is installed.
    vulkan_validation: bool = false,
    /// Print per-frame synchronization timings every 60 frames.
    trace: bool = false,
    /// Open this many extra 800x600 views at startup, for testing multi-view
    /// rendering without clicking anything.
    extra_windows: u32 = 0,
    /// Create the initial xdg_toplevel that backs the implicit view. Set to
    /// false for a layer-only app (a bar or wallpaper) whose Dart entry point
    /// renders a `ViewCollection` of layer windows instead.
    initial_window: bool = true,
    /// Exercise the exported windowing ABI from the event loop.
    windowing_spike: bool = false,
    /// Extra engine switches, as passed by Flutter's custom-device
    /// `runDebug` `${engineOptions}`. The strings are borrowed until
    /// `Runtime.init` returns; the runtime does not keep them.
    engine_args: []const []const u8 = &.{},

    /// Read the `FILO_*` environment variables. This keeps the development
    /// runner working; a host that has its own configuration should construct
    /// `Config` directly.
    pub fn fromEnv(map: *const std.process.Environ.Map) !Config {
        return .{
            .engine_lib = try required(map, "FILO_ENGINE_LIB"),
            .icu_data = try required(map, "FILO_ICU_DATA"),
            .assets = try required(map, "FILO_ASSETS"),
            .aot_lib = map.get("FILO_AOT_LIB"),
            .force_impeller = map.get("FORCE_IMPELLER") != null,
            .vulkan_validation = map.get("FILO_VULKAN_VALIDATION") != null,
            .trace = map.get("FILO_TRACE") != null,
            .extra_windows = if (map.get("FILO_EXTRA_WINDOWS")) |value|
                std.fmt.parseInt(u32, value, 10) catch 2
            else
                0,
            .initial_window = map.get("FILO_NO_INITIAL_WINDOW") == null,
            .windowing_spike = map.get("FILO_WINDOWING_SPIKE") != null,
        };
    }
};

/// Backwards-compatible name for the old entry point.
pub fn load(map: *const std.process.Environ.Map) !Config {
    return Config.fromEnv(map);
}

fn required(map: *const std.process.Environ.Map, name: []const u8) ![]const u8 {
    return map.get(name) orelse {
        std.debug.print("filo: required environment variable {s} is not set\n", .{name});
        return error.MissingEnvironmentVariable;
    };
}
