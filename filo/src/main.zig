//! Development runner for the embedder. Hosts that consume filo as a package
//! import the `filo` module directly; this exe only reads the `FILO_*`
//! environment variables and runs the same public API.
//!
//! Command-line arguments are passed to Dart's `main(List<String> args)`.
//! Engine switches from Flutter's custom-device `${engineOptions}` are not
//! forwarded yet.
//!
//! It is built only when filo is the root package (see `build.zig`).

const std = @import("std");
const filo = @import("filo");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var config = try filo.Config.fromEnv(init.environ_map);
    config.dart_entrypoint_args = if (argv.len > 1) argv[1..] else argv[0..0];

    const runtime = try filo.Runtime.init(init.gpa, init.io, config);
    defer runtime.deinit();
    try runtime.run();
}
