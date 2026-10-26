const std = @import("std");

/// The layer surface the embedder creates for the implicit view when
/// `bootstrap_layer` is true. The first layer controller should use the same
/// properties; otherwise it reconfigures the surface and can race its first
/// frame.
pub const LayerBootstrap = struct {
    /// `zwlr_layer_shell_v1.layer`: 0 background, 1 bottom, 2 top, 3 overlay.
    layer: i32 = 2,
    /// `zwlr_layer_surface_v1.anchor`: 1 top, 2 bottom, 4 left, 8 right.
    anchor: u32 = 1 | 8,
    exclusive_zone: i32 = 0,
    /// 0 none, 1 exclusive, 2 on-demand.
    keyboard_interactivity: i32 = 2,
    margin_top: i32 = 8,
    margin_right: i32 = 8,
    margin_bottom: i32 = 0,
    margin_left: i32 = 0,
    width: u32 = 300,
    height: u32 = 300,
    namespace: [:0]const u8 = "filo",
    accepts_input: bool = true,
};

/// Everything the embedder needs to start, passed by the host. Path strings are
/// copied by `Runtime.init`; `engine_args` and `dart_entrypoint_args` are only
/// read during it.
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
    /// Bootstrap the implicit view (id 0) as a layer surface instead of an
    /// xdg_toplevel. This only chooses view 0's role; it does not restrict the
    /// windows the app may create.
    bootstrap_layer: bool = false,
    /// The layer surface created for the implicit view when [bootstrap_layer]
    /// is true. The first layer controller should use the same values.
    bootstrap_layer_surface: LayerBootstrap = .{},
    /// Exercise the exported windowing ABI from the event loop.
    windowing_spike: bool = false,
    /// Extra engine switches supplied by the host. Flutter's custom-device
    /// `${engineOptions}` are not forwarded yet. The strings are borrowed until
    /// `Runtime.init` returns; the runtime does not keep them.
    engine_args: []const []const u8 = &.{},
    /// Arguments passed to the Dart entrypoint, as `main(List<String> args)`.
    /// The strings are borrowed until `Runtime.init` returns; the engine copies
    /// them while initializing.
    dart_entrypoint_args: []const []const u8 = &.{},

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
            // Development-runner switch for the layer-only demo. Hosts should
            // construct Config directly when they need this.
            .bootstrap_layer = map.get("FILO_LAYER_ONLY") != null,
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
