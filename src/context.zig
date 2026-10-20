const std = @import("std");

const ev = @import("zio").ev;

const connection = @import("wayland/connection.zig");
const engine = @import("engine.zig");

/// The globals every callback can reach. A callback that needs only these
/// receives a `*Context`; one that also needs its own state receives a struct
/// that has `ctx: *Context` as a field, plus that state.
pub const Context = struct {
    allocator: std.mem.Allocator,
    loop: *ev.Loop,
    conn: *connection.Connection,
    eng: *engine.Engine,
};
