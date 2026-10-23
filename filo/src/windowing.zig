//! The native side of the `filo_windowing` backend contract.
//!
//! Dart reaches these symbols through `dart:ffi`. The embedder installs a
//! `Host` at startup; the exported functions are thin, C-ABI wrappers around it
//! so the wire structs live in one place and the implementation stays in
//! `main.zig`, where the `App` and its window registry live.
//!
//! The functions must be called from the main (UI) thread. `AddView` is only
//! synchronous on that thread; see `engine.zig`'s task-runner comment.

const std = @import("std");

/// The two xdg-shell roles. The Dart controller types (regular, dialog,
/// tooltip, popup, satellite) all map onto one of these plus the request flags.
pub const Kind = enum(i32) {
    toplevel = 0,
    popup = 1,
};

pub const Size = extern struct {
    width: u32,
    height: u32,
};

pub const Offset = extern struct {
    x: i32,
    y: i32,
};

pub const Rect = extern struct {
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

/// Mirrors `FiloPositioner` in the Dart package, i.e. `xdg_positioner`.
/// `anchor`/`gravity` use the same numeric values as `xdg_positioner`, and
/// `constraint_adjustment` is its bitmask verbatim.
pub const Positioner = extern struct {
    size: Size,
    anchor_rect: Rect,
    anchor: i32,
    gravity: i32,
    constraint_adjustment: u32,
    offset: Offset,
};

/// One `createWindow` request. All sizes are logical pixels.
pub const WindowRequest = extern struct {
    kind: i32,
    /// Preferred content size; 0 × 0 means size to content.
    size: Size,
    // 0 / maxInt(i32) mean unbounded.
    min_size: Size,
    max_size: Size,
    resizable: u8,
    sized_to_content: u8,
    modal: u8,
    decorated: u8,
    /// NUL-terminated, nullable. Copied before the call returns.
    title: ?[*:0]const u8,
    /// -1 means no parent.
    parent_view_id: i64,
    /// Suggested view id (0 = adopt the implicit view if possible).
    preferred_view_id: i64,
    /// Popups/satellites.
    positioner: Positioner,
};

/// The initial state of a created window, so a controller can be fully built
/// before any event is delivered.
pub const WindowHandle = extern struct {
    view_id: i64,
    content_size: Size,
    /// NUL-terminated; valid only for the duration of the create call.
    title: ?[*:0]const u8,
    /// Bitmask of `ToplevelState`; several states can be set at once.
    toplevel_state: u32,
    /// Bitmask of `WmCapabilities`.
    wm_capabilities: u32,
    /// Popups: top-left corner relative to the parent client area.
    offset_from_parent: Offset,
};

/// `xdg_toplevel.state` / `FiloToplevelState` as a bitmask. State value `n`
/// (1-based in the Dart enum) is bit `n - 1`, and several may be set at once.
pub const ToplevelState = struct {
    pub const maximized: u32 = 1 << 0;
    pub const fullscreen: u32 = 1 << 1;
    pub const resizing: u32 = 1 << 2;
    pub const activated: u32 = 1 << 3;
    pub const tiled_left: u32 = 1 << 4;
    pub const tiled_right: u32 = 1 << 5;
    pub const tiled_top: u32 = 1 << 6;
    pub const tiled_bottom: u32 = 1 << 7;
    pub const suspended: u32 = 1 << 8;
    pub const constrained_left: u32 = 1 << 9;
    pub const constrained_right: u32 = 1 << 10;
    pub const constrained_top: u32 = 1 << 11;
    pub const constrained_bottom: u32 = 1 << 12;
};

/// `xdg_toplevel.wm_capabilities` / `FiloToplevelWMCapabilities` as a bitmask.
pub const WmCapabilities = struct {
    pub const window_menu: u32 = 1 << 0;
    pub const maximize: u32 = 1 << 1;
    pub const fullscreen: u32 = 1 << 2;
    pub const minimize: u32 = 1 << 3;
};

pub const ConfigureFn = *const fn (width: i32, height: i32) callconv(.c) void;
pub const StateFn = *const fn (toplevel_state: u32) callconv(.c) void;
pub const CapabilitiesFn = *const fn (wm_capabilities: u32) callconv(.c) void;
pub const TitleFn = *const fn (title: [*:0]const u8) callconv(.c) void;
pub const MovedFn = *const fn (x: i32, y: i32) callconv(.c) void;
pub const NotifyFn = *const fn () callconv(.c) void;

/// Per-window event callbacks. Dart registers `NativeCallable`s for the ones it
/// cares about and must keep them alive until `on_destroy` has been invoked.
pub const WindowCallbacks = extern struct {
    on_configure: ?ConfigureFn,
    on_state: ?StateFn,
    on_capabilities: ?CapabilitiesFn,
    on_title: ?TitleFn,
    on_moved: ?MovedFn,
    on_close: ?NotifyFn,
    on_destroy: ?NotifyFn,
};

pub const empty_callbacks = WindowCallbacks{
    .on_configure = null,
    .on_state = null,
    .on_capabilities = null,
    .on_title = null,
    .on_moved = null,
    .on_close = null,
    .on_destroy = null,
};

pub const Status = enum(i32) { ok = 0, invalid_argument = 1, unknown_view = 2, unsupported = 3, backend_failed = 4 };

/// The embedder's implementation of the ABI. `main.zig` fills this in and calls
/// `install` once the `App` exists.
pub const Host = struct {
    ctx: ?*anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        create: *const fn (ctx: ?*anyopaque, request: *WindowRequest, out: *WindowHandle) Status,
        destroy: *const fn (ctx: ?*anyopaque, view_id: i64) void,
        observe: *const fn (ctx: ?*anyopaque, view_id: i64, callbacks: WindowCallbacks) Status,

        set_title: *const fn (ctx: ?*anyopaque, view_id: i64, title: ?[*:0]const u8) Status,
        set_size: *const fn (ctx: ?*anyopaque, view_id: i64, size: Size) Status,
        set_constraints: *const fn (ctx: ?*anyopaque, view_id: i64, min: Size, max: Size) Status,
        activate: *const fn (ctx: ?*anyopaque, view_id: i64) Status,
        set_maximized: *const fn (ctx: ?*anyopaque, view_id: i64, maximized: bool) Status,
        set_minimized: *const fn (ctx: ?*anyopaque, view_id: i64, minimized: bool) Status,
        set_fullscreen: *const fn (ctx: ?*anyopaque, view_id: i64, fullscreen: bool) Status,
        set_parent: *const fn (ctx: ?*anyopaque, view_id: i64, parent_view_id: i64) Status,
        update_position: *const fn (ctx: ?*anyopaque, view_id: i64, anchor: ?*const Rect, positioner: ?*const Positioner) Status,

        get_size: *const fn (ctx: ?*anyopaque, view_id: i64, out: *Size) Status,
        get_state: *const fn (ctx: ?*anyopaque, view_id: i64, out: *u32) Status,
        get_capabilities: *const fn (ctx: ?*anyopaque, view_id: i64, out: *u32) Status,
        get_title: *const fn (ctx: ?*anyopaque, view_id: i64, buf: [*]u8, len: u32) Status,
        get_offset: *const fn (ctx: ?*anyopaque, view_id: i64, out: *Offset) Status,
    };

    pub fn create(self: Host, request: *WindowRequest, out: *WindowHandle) Status {
        return self.vtable.create(self.ctx, request, out);
    }

    pub fn destroy(self: Host, view_id: i64) void {
        return self.vtable.destroy(self.ctx, view_id);
    }

    pub fn observe(self: Host, view_id: i64, callbacks: WindowCallbacks) Status {
        return self.vtable.observe(self.ctx, view_id, callbacks);
    }

    pub fn setTitle(self: Host, view_id: i64, title: ?[*:0]const u8) Status {
        return self.vtable.set_title(self.ctx, view_id, title);
    }

    pub fn setSize(self: Host, view_id: i64, size: Size) Status {
        return self.vtable.set_size(self.ctx, view_id, size);
    }

    pub fn setConstraints(self: Host, view_id: i64, min: Size, max: Size) Status {
        return self.vtable.set_constraints(self.ctx, view_id, min, max);
    }

    pub fn activate(self: Host, view_id: i64) Status {
        return self.vtable.activate(self.ctx, view_id);
    }

    pub fn setMaximized(self: Host, view_id: i64, maximized: bool) Status {
        return self.vtable.set_maximized(self.ctx, view_id, maximized);
    }

    pub fn setMinimized(self: Host, view_id: i64, minimized: bool) Status {
        return self.vtable.set_minimized(self.ctx, view_id, minimized);
    }

    pub fn setFullscreen(self: Host, view_id: i64, fullscreen: bool) Status {
        return self.vtable.set_fullscreen(self.ctx, view_id, fullscreen);
    }

    pub fn setParent(self: Host, view_id: i64, parent_view_id: i64) Status {
        return self.vtable.set_parent(self.ctx, view_id, parent_view_id);
    }

    pub fn updatePosition(
        self: Host,
        view_id: i64,
        anchor: ?*const Rect,
        positioner: ?*const Positioner,
    ) Status {
        return self.vtable.update_position(self.ctx, view_id, anchor, positioner);
    }

    pub fn getSize(self: Host, view_id: i64, out: *Size) Status {
        return self.vtable.get_size(self.ctx, view_id, out);
    }

    pub fn getState(self: Host, view_id: i64, out: *u32) Status {
        return self.vtable.get_state(self.ctx, view_id, out);
    }

    pub fn getCapabilities(self: Host, view_id: i64, out: *u32) Status {
        return self.vtable.get_capabilities(self.ctx, view_id, out);
    }

    pub fn getTitle(self: Host, view_id: i64, buf: [*]u8, len: u32) Status {
        return self.vtable.get_title(self.ctx, view_id, buf, len);
    }

    pub fn getOffset(self: Host, view_id: i64, out: *Offset) Status {
        return self.vtable.get_offset(self.ctx, view_id, out);
    }
};

var host: Host = undefined;

pub fn install(new_host: Host) void {
    host = new_host;
}

//------------------------------------------------------------------------------
// Exported C ABI. These are the symbols Dart looks up on the process image.
//------------------------------------------------------------------------------

pub export fn filo_window_create(request: ?*WindowRequest, out: ?*WindowHandle) i32 {
    const req = request orelse return @backingInt(Status.invalid_argument);
    const handle = out orelse return @backingInt(Status.invalid_argument);
    handle.* = std.mem.zeroes(WindowHandle);
    return @backingInt(host.create(req, handle));
}

pub export fn filo_window_destroy(view_id: i64) i32 {
    host.destroy(view_id);
    return @backingInt(Status.ok);
}

pub export fn filo_window_observe(
    view_id: i64,
    on_configure: ?ConfigureFn,
    on_state: ?StateFn,
    on_capabilities: ?CapabilitiesFn,
    on_title: ?TitleFn,
    on_moved: ?MovedFn,
    on_close: ?NotifyFn,
    on_destroy: ?NotifyFn,
) i32 {
    return @backingInt(host.observe(view_id, .{
        .on_capabilities = on_capabilities,
        .on_close = on_close,
        .on_configure = on_configure,
        .on_destroy = on_destroy,
        .on_moved = on_moved,
        .on_state = on_state,
        .on_title = on_title,
    }));
}

pub export fn filo_window_set_title(view_id: i64, title: ?[*:0]const u8) i32 {
    return @backingInt(host.setTitle(view_id, title));
}

pub export fn filo_window_set_size(view_id: i64, width: i32, height: i32) i32 {
    if (width < 0 or height < 0) return @backingInt(Status.invalid_argument);
    return @backingInt(host.setSize(view_id, .{ .width = @intCast(width), .height = @intCast(height) }));
}

pub export fn filo_window_set_constraints(
    view_id: i64,
    min_width: i32,
    min_height: i32,
    max_width: i32,
    max_height: i32,
) i32 {
    if (min_width < 0 or min_height < 0 or max_width < 0 or max_height < 0) {
        return @backingInt(Status.invalid_argument);
    }
    return @backingInt(host.setConstraints(
        view_id,
        .{ .width = @intCast(min_width), .height = @intCast(min_height) },
        .{ .width = @intCast(max_width), .height = @intCast(max_height) },
    ));
}

pub export fn filo_window_activate(view_id: i64) i32 {
    return @backingInt(host.activate(view_id));
}

pub export fn filo_window_set_maximized(view_id: i64, maximized: u8) i32 {
    return @backingInt(host.setMaximized(view_id, maximized != 0));
}

pub export fn filo_window_set_minimized(view_id: i64, minimized: u8) i32 {
    return @backingInt(host.setMinimized(view_id, minimized != 0));
}

pub export fn filo_window_set_fullscreen(view_id: i64, fullscreen: u8) i32 {
    return @backingInt(host.setFullscreen(view_id, fullscreen != 0));
}

pub export fn filo_window_set_parent(view_id: i64, parent_view_id: i64) i32 {
    return @backingInt(host.setParent(view_id, parent_view_id));
}

pub export fn filo_window_update_position(
    view_id: i64,
    anchor: ?*const Rect,
    positioner: ?*const Positioner,
) i32 {
    return @backingInt(host.updatePosition(view_id, anchor, positioner));
}

pub export fn filo_window_get_size(view_id: i64, out: ?*Size) i32 {
    const size = out orelse return @backingInt(Status.invalid_argument);
    return @backingInt(host.getSize(view_id, size));
}

pub export fn filo_window_get_state(view_id: i64, out: ?*u32) i32 {
    const state = out orelse return @backingInt(Status.invalid_argument);
    return @backingInt(host.getState(view_id, state));
}

pub export fn filo_window_get_capabilities(view_id: i64, out: ?*u32) i32 {
    const capabilities = out orelse return @backingInt(Status.invalid_argument);
    return @backingInt(host.getCapabilities(view_id, capabilities));
}

pub export fn filo_window_get_title(view_id: i64, buf: ?[*]u8, len: u32) i32 {
    const buffer = buf orelse return @backingInt(Status.invalid_argument);
    return @backingInt(host.getTitle(view_id, buffer, len));
}

pub export fn filo_window_get_offset(view_id: i64, out: ?*Offset) i32 {
    const offset = out orelse return @backingInt(Status.invalid_argument);
    return @backingInt(host.getOffset(view_id, offset));
}

//------------------------------------------------------------------------------
// Tests
//------------------------------------------------------------------------------

test "the wire structs use C layout" {
    // The handle is the stable part the Dart side mirrors; a field changing
    // place would silently break the bridge.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(WindowHandle, "view_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(WindowHandle, "content_size"));
    try std.testing.expectEqual(@sizeOf(?*const anyopaque), @sizeOf(?[*:0]const u8));
    try std.testing.expect(@sizeOf(WindowRequest) > @sizeOf(WindowHandle));
}

var test_seen: i64 = 0;

fn testCreate(_: ?*anyopaque, _: *const WindowRequest, out: *WindowHandle) Status {
    out.* = std.mem.zeroes(WindowHandle);
    out.view_id = 42;
    out.content_size = .{ .width = 640, .height = 480 };
    test_seen = 42;
    return .ok;
}

fn testDestroy(_: ?*anyopaque, view_id: i64) void {
    test_seen = view_id;
}

fn testObserve(_: ?*anyopaque, _: i64, _: WindowCallbacks) Status {
    return .ok;
}

fn testStatus0(_: ?*anyopaque, _: i64) Status {
    return .unsupported;
}

fn testStatusBool(_: ?*anyopaque, _: i64, _: bool) Status {
    return .unsupported;
}

fn testStatusSize(_: ?*anyopaque, _: i64, _: Size) Status {
    return .unsupported;
}

fn testStatusConstraints(_: ?*anyopaque, _: i64, _: Size, _: Size) Status {
    return .unsupported;
}

fn testStatusParent(_: ?*anyopaque, _: i64, _: i64) Status {
    return .unsupported;
}

fn testUpdatePosition(_: ?*anyopaque, _: i64, _: ?*const Rect, _: ?*const Positioner) Status {
    return .unsupported;
}

fn testStatusTitle(_: ?*anyopaque, _: i64, _: ?[*:0]const u8) Status {
    return .unsupported;
}

fn testGetSize(_: ?*anyopaque, _: i64, _: *Size) Status {
    return .unsupported;
}

fn testGetU32(_: ?*anyopaque, _: i64, _: *u32) Status {
    return .unsupported;
}

fn testGetTitle(_: ?*anyopaque, _: i64, _: [*]u8, _: u32) Status {
    return .unsupported;
}

fn testGetOffset(_: ?*anyopaque, _: i64, _: *Offset) Status {
    return .unsupported;
}

test "the exported entry points forward to the host" {
    const fake = Host{
        .ctx = null,
        .vtable = .{
            .create = testCreate,
            .destroy = testDestroy,
            .observe = testObserve,
            .set_title = testStatusTitle,
            .set_size = testStatusSize,
            .set_constraints = testStatusConstraints,
            .activate = testStatus0,
            .set_maximized = testStatusBool,
            .set_minimized = testStatusBool,
            .set_fullscreen = testStatusBool,
            .set_parent = testStatusParent,
            .update_position = testUpdatePosition,
            .get_size = testGetSize,
            .get_state = testGetU32,
            .get_capabilities = testGetU32,
            .get_title = testGetTitle,
            .get_offset = testGetOffset,
        },
    };
    install(fake);

    var request = std.mem.zeroes(WindowRequest);
    var handle = std.mem.zeroes(WindowHandle);
    handle.view_id = 99;
    try std.testing.expectEqual(@as(i32, 0), filo_window_create(&request, &handle));
    try std.testing.expectEqual(@as(i64, 42), handle.view_id);
    try std.testing.expectEqual(@as(u32, 640), handle.content_size.width);

    try std.testing.expectEqual(@as(i32, 0), filo_window_destroy(7));
    try std.testing.expectEqual(@as(i64, 7), test_seen);
}
