const std = @import("std");

const filo = @import("filo/build.zig");

/// Repository-root package.
///
/// The embedder itself lives in `filo/`. This package exists so consumers can
/// fetch the repository URL directly:
///
///     zig fetch --save=filo git+https://github.com/ross96D/filo#master
///
/// and then import the module it exposes:
///
///     b.dependency("filo", .{ ... }).module("filo")
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = filo.addModule(b, target, optimize, "filo");
}
