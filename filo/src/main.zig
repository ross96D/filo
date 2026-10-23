//! Development runner for the embedder. Hosts that consume filo as a package
//! import the `filo` module directly; this exe only reads the `FILO_*`
//! environment variables and runs the same public API.
//!
//! It is built only when filo is the root package (see `build.zig`).

const std = @import("std");
const filo = @import("filo");

pub fn main(init: std.process.Init) !void {
    const config = try filo.Config.fromEnv(init.environ_map);
    try filo.run(init.gpa, init.io, config);
}
