//! The native side of the `filo_windowing` backend contract.
//!
//! Dart reaches these symbols through `dart:ffi`. The embedder installs a
//! `Host` at startup; the exported functions are thin, C-ABI wrappers around it
//! so the wire structs live in one place and the implementation stays in
//! `main.zig`, where the `App` and its window registry live.
//!
//! The functions must be called from the main (UI) thread. `AddView` is only
//! synchronous on that thread; see `engine.onMainThread`.

const std = @import("std");

/// The semantic window roles from the backend contract (doc/backend.md).
pub const Kind = enum(i32) {
    regular = 0,
    dialog = 1,
    tooltip = 2,
    popup = 3,
    satellite = 4,
};

/// Matches `FiloPositionerAnchor` in the Dart package (and `xdg_positioner`).
pub const PositionerAnchor = enum(i32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
};

/// Matches `FiloPositionerGravity` in the Dart package (and `xdg_positioner`).
pub const PositionerGravity = enum(i32) {
    none = 0,
    top = 1,
    bottom = 2,
    left = 3,
    right = 4,
    top_left = 5,
    bottom_left = 6,
    top_right = 7,
    bottom_right = 8,
};

/// Matches `FiloPositioner`/`FiloPositionerConstrainsAdjustmentsFlags`. The
/// `constraint_adjustment` bits are the `xdg_positioner` bits verbatim.
pub const Positioner = extern struct {
    anchor: i32,
    gravity: i32,
    constraint_adjustment: u32,
    offset_x: i32,
    offset_y: i32,
};

/// One `createWindow` request. All sizes are logical pixels.
pub const WindowRequest = extern struct {
    kind: i32,
    /// 0 × 0 means size to content.
    width: i32,
    height: i32,
    // 0 / maxInt(i32) mean unbounded.
    min_w: i32,
    min_h: i32,
    max_w: i32,
    max_h: i32,
    resizable: u8,
    sized_to_content: u8,
    modal: u8,
    decorated: u8,
    /// NUL-terminated, nullable. Copied before the call returns.
    title: ?[*:0]const u8,
    /// 0 means no parent.
    parent_view_id: i64,
    /// Suggested view id (0 = adopt the implicit view if possible).
    preferred_view_id: i64,
    // In logical pixels, for popups/satellites.
    anchor_x: i32,
    anchor_y: i32,
    anchor_w: i32,
    anchor_h: i32,
    positioner: Positioner,
};

/// The initial state of a created window, so a controller can be fully built
/// before any event is delivered.
pub const WindowHandle = extern struct {
    view_id: i64,
    content_width: i32,
    content_height: i32,
    /// NUL-terminated; valid only for the duration of the create call.
    title: ?[*:0]const u8,
    /// maximized=1, minimized=2, fullscreen=4, activated=8.
    state_bits: u32,
    /// Popups: top-left corner relative to the parent client area.
    offset_x: i32,
    offset_y: i32,
};

pub const StateBits = struct {
    pub const maximized: u32 = 1 << 0;
    pub const minimized: u32 = 1 << 1;
    pub const fullscreen: u32 = 1 << 2;
    pub const activated: u32 = 1 << 3;
};

pub const ConfigureFn = *const fn (width: i32, height: i32) callconv(.c) void;
pub const StateFn = *const fn (state_bits: u32) callconv(.c) void;
pub const TitleFn = *const fn (title: [*:0]const u8) callconv(.c) void;
pub const MovedFn = *const fn (x: i32, y: i32) callconv(.c) void;
pub const NotifyFn = *const fn () callconv(.c) void;

/// Per-window event callbacks. Dart registers `NativeCallable`s for the ones it
/// cares about and must keep them alive until `on_destroy` has been invoked.
pub const WindowCallbacks = extern struct {
    on_configure: ?ConfigureFn,
    on_state: ?StateFn,
    on_title: ?TitleFn,
    on_moved: ?MovedFn,
    on_close: ?NotifyFn,
    on_destroy: ?NotifyFn,
};

pub const empty_callbacks = WindowCallbacks{
    .on_configure = null,
    .on_state = null,
    .on_title = null,
    .on_moved = null,
    .on_close = null,
    .on_destroy = null,
};

pub const Status = enum(i32) {
    ok = 0,
    invalid_argument = 1,
    unknown_view = 2,
    unsupported = 3,
    backend_failed = 4,
    wrong_thread = 5,
};

/// The embedder's implementation of the ABI. `main.zig` fills this in and calls
/// `install` once the `App` exists.
pub const Host = struct {
    ctx: ?*anyopaque,
    vtable: VTable,

    pub const VTable = struct {
        create: *const fn (ctx: ?*anyopaque, request: *const WindowRequest, out: *WindowHandle) Status,
        destroy: *const fn (ctx: ?*anyopaque, view_id: i64) void,
        observe: *const fn (ctx: ?*anyopaque, view_id: i64, callbacks: *const WindowCallbacks) Status,
    };

    pub fn create(self: Host, request: *const WindowRequest, out: *WindowHandle) Status {
        return self.vtable.create(self.ctx, request, out);
    }

    pub fn destroy(self: Host, view_id: i64) void {
        return self.vtable.destroy(self.ctx, view_id);
    }

    pub fn observe(self: Host, view_id: i64, callbacks: *const WindowCallbacks) Status {
        return self.vtable.observe(self.ctx, view_id, callbacks);
    }
};

var host: Host = undefined;

pub fn install(new_host: Host) void {
    host = new_host;
}

//------------------------------------------------------------------------------
// Exported C ABI. These are the symbols Dart looks up on the process image.
//------------------------------------------------------------------------------

pub export fn filo_window_create(request: ?*const WindowRequest, out: ?*WindowHandle) i32 {
    const req = request orelse return @backingInt(Status.invalid_argument);
    const handle = out orelse return @backingInt(Status.invalid_argument);
    handle.* = std.mem.zeroes(WindowHandle);
    return @backingInt(host.create(req, handle));
}

pub export fn filo_window_destroy(view_id: i64) i32 {
    host.destroy(view_id);
    return @backingInt(Status.ok);
}

pub export fn filo_window_observe(view_id: i64, callbacks: ?*const WindowCallbacks) i32 {
    const cbs = callbacks orelse return @backingInt(Status.invalid_argument);
    return @backingInt(host.observe(view_id, cbs));
}

//------------------------------------------------------------------------------
// Tests
//------------------------------------------------------------------------------

test "the wire structs use C layout" {
    // The handle is the stable part the Dart side mirrors; a field changing
    // place would silently break the bridge.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(WindowHandle, "view_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(WindowHandle, "content_width"));
    try std.testing.expectEqual(@sizeOf(?*const anyopaque), @sizeOf(?[*:0]const u8));
    try std.testing.expect(@sizeOf(WindowRequest) > @sizeOf(WindowHandle));
}

var test_seen: i64 = 0;

fn testCreate(_: ?*anyopaque, _: *const WindowRequest, out: *WindowHandle) Status {
    out.* = std.mem.zeroes(WindowHandle);
    out.view_id = 42;
    out.content_width = 640;
    out.content_height = 480;
    test_seen = 42;
    return .ok;
}

fn testDestroy(_: ?*anyopaque, view_id: i64) void {
    test_seen = view_id;
}

fn testObserve(_: ?*anyopaque, _: i64, _: *const WindowCallbacks) Status {
    return .ok;
}

test "the exported entry points forward to the host" {
    var fake = Host{
        .ctx = null,
        .create = testCreate,
        .destroy = testDestroy,
        .observe = testObserve,
    };
    install(&fake);
    defer host = null;

    var request = std.mem.zeroes(WindowRequest);
    var handle = std.mem.zeroes(WindowHandle);
    handle.view_id = 99;
    try std.testing.expectEqual(@as(i32, 0), filo_window_create(&request, &handle));
    try std.testing.expectEqual(@as(i64, 42), handle.view_id);
    try std.testing.expectEqual(@as(i32, 640), handle.content_width);

    try std.testing.expectEqual(@as(i32, 0), filo_window_destroy(7));
    try std.testing.expectEqual(@as(i64, 7), test_seen);
}
