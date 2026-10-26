//! Wayland host for a Flutter application using filo.
//!
//! The Flutter tool launches this executable from the app's `wayland/` folder
//! through a custom device. It reads the same `FILO_*` environment variables as
//! the development runner.
//!
//! Command-line arguments are passed to Dart's `main(List<String> args)`.
//! Engine switches from Flutter's custom-device `${engineOptions}` are not
//! forwarded yet.
//!
//! Extra native code and future plugins belong here: add modules to
//! `build.zig`, import them below, and initialize them before `filo.run`.

const std = @import("std");
const filo = @import("filo");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const argv = try init.minimal.args.toSlice(arena);

    var config = try filo.Config.fromEnv(init.environ_map);
    // argv[0] is this executable; everything after it goes to Dart.
    config.dart_entrypoint_args = if (argv.len > 1) argv[1..] else argv[0..0];

    const runtime = try filo.Runtime.init(init.gpa, init.io, config);
    defer runtime.deinit();
    try runtime.run();
}
