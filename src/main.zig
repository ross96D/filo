const std = @import("std");

const engine = @import("engine.zig");
const window = @import("window.zig");
const manifest = @import("manifest.zig");

const width = 800;
const height = 600;
const pixel_ratio = 1.0;

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    const cfg = try manifest.load(init.environ_map);

    var eng = try engine.Engine.init(allocator, cfg);
    defer eng.deinit();

    eng.sendWindowMetrics(width, height, pixel_ratio);

    const win = try window.Window.create(allocator, width, height);
    defer win.destroy();

    std.debug.print("fembed: window created, entering event loop\n", .{});
    try win.run();
}
