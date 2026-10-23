const std = @import("std");

const c = @import("flutter");
const xkb = @import("xkb");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const engine = @import("engine.zig");
const keyboard = @import("flutter/keyboard.zig");
const text_input = @import("flutter/text_input.zig");

const CONTEXT_NO_FLAGS: xkb.enum_xkb_context_flags = @intCast(xkb.XKB_CONTEXT_NO_FLAGS);
const KEYMAP_FORMAT_TEXT_V1: xkb.enum_xkb_keymap_format = @intCast(xkb.XKB_KEYMAP_FORMAT_TEXT_V1);
const KEYMAP_COMPILE_NO_FLAGS: xkb.enum_xkb_keymap_compile_flags = @intCast(xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
const KEY_DOWN: xkb.enum_xkb_key_direction = @intCast(xkb.XKB_KEY_DOWN);
const KEY_UP: xkb.enum_xkb_key_direction = @intCast(xkb.XKB_KEY_UP);

/// Build a GDK-style modifier mask from the active XKB modifiers. Flutter's
/// RawKeyEventDataLinux reads this bitmask with GdkModifierType semantics.
fn modifierMask(state: *xkb.xkb_state) u32 {
    const effective: xkb.enum_xkb_state_component = @intCast(xkb.XKB_STATE_MODS_EFFECTIVE);
    var mask: u32 = 0;
    if (xkb.xkb_state_mod_name_is_active(state, "Shift", effective) != 0) mask |= 1 << 0;
    if (xkb.xkb_state_mod_name_is_active(state, "Lock", effective) != 0) mask |= 1 << 1;
    if (xkb.xkb_state_mod_name_is_active(state, "Control", effective) != 0) mask |= 1 << 2;
    if (xkb.xkb_state_mod_name_is_active(state, "Mod1", effective) != 0) mask |= 1 << 3;
    if (xkb.xkb_state_mod_name_is_active(state, "Mod2", effective) != 0) mask |= 1 << 4;
    if (xkb.xkb_state_mod_name_is_active(state, "Mod4", effective) != 0) mask |= 1 << 28;
    return mask;
}

pub const Input = struct {
    eng: *engine.Engine,
    text_input: *text_input.TextInput,
    xkb_ctx: ?*xkb.xkb_context,
    keymap: ?*xkb.xkb_keymap,
    state: ?*xkb.xkb_state,
    mouse_x: f64,
    mouse_y: f64,
    buttons: i64,
    device: i32,
    /// The view the pointer is currently over. Pointer events carry it, while
    /// the engine routes keyboard events to whichever view it considers focused.
    pointer_view: engine.ViewId,
    /// The view that last received platform keyboard focus, if any.
    focused_view: ?engine.ViewId,
    resolve_ctx: ?*anyopaque = null,
    resolve_fn: ?*const fn (?*anyopaque, *wl.Surface) ?engine.ViewId = null,

    pub fn init(eng: *engine.Engine, ti: *text_input.TextInput) !Input {
        const ctx = xkb.xkb_context_new(CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        return .{
            .eng = eng,
            .text_input = ti,
            .xkb_ctx = ctx,
            .keymap = null,
            .state = null,
            .mouse_x = 0,
            .mouse_y = 0,
            .buttons = 0,
            .device = 0,
            .pointer_view = 0,
            .focused_view = null,
        };
    }

    /// Give the input handler the window registry's surface → view lookup. The
    /// connection owns the seat listeners; this is how it finds the view a
    /// surface belongs to.
    pub fn setViewResolver(
        self: *Input,
        ctx: ?*anyopaque,
        resolve: *const fn (?*anyopaque, *wl.Surface) ?engine.ViewId,
    ) void {
        self.resolve_ctx = ctx;
        self.resolve_fn = resolve;
    }

    fn viewForSurface(self: *Input, surface: ?*wl.Surface) ?engine.ViewId {
        const s = surface orelse return null;
        const resolve = self.resolve_fn orelse return null;
        return resolve(self.resolve_ctx, s);
    }

    pub fn deinit(self: *Input) void {
        if (self.state) |s| xkb.xkb_state_unref(s);
        if (self.keymap) |k| xkb.xkb_keymap_unref(k);
        if (self.xkb_ctx) |ctx| xkb.xkb_context_unref(ctx);
    }

    /// The seat's keyboard entered `surface`: that window's view now has
    /// platform focus. Sent once per transition; the compositor can repeat an
    /// enter without an intervening leave.
    pub fn keyboardEnter(self: *Input, surface: ?*wl.Surface) void {
        const view_id = self.viewForSurface(surface) orelse return;

        if (self.focused_view) |previous| {
            if (previous == view_id) return;
            self.eng.sendViewFocusEvent(previous, .unfocused, .none);
        }
        self.focused_view = view_id;
        std.debug.print("filo: view {} gained focus\n", .{view_id});
        self.eng.sendViewFocusEvent(view_id, .focused, .none);
    }

    /// The seat's keyboard left the surface: the view no longer has platform
    /// focus.
    pub fn keyboardLeave(self: *Input) void {
        const view_id = self.focused_view orelse return;
        self.focused_view = null;
        std.debug.print("filo: view {} lost focus\n", .{view_id});
        self.eng.sendViewFocusEvent(view_id, .unfocused, .none);
    }

    /// Install a new keymap from the raw XKB text provided by wl_keyboard.keymap.
    pub fn setKeymapFromBuffer(self: *Input, buffer: []const u8) void {
        if (self.state) |s| xkb.xkb_state_unref(s);
        if (self.keymap) |k| xkb.xkb_keymap_unref(k);
        self.keymap = xkb.xkb_keymap_new_from_buffer(
            self.xkb_ctx,
            buffer.ptr,
            buffer.len,
            KEYMAP_FORMAT_TEXT_V1,
            KEYMAP_COMPILE_NO_FLAGS,
        );
        if (self.keymap == null) {
            std.debug.print("filo: failed to compile xkb keymap\n", .{});
        }
        self.state = if (self.keymap) |k| xkb.xkb_state_new(k) else null;
    }

    pub fn updateModifiers(self: *Input, depressed: u32, latched: u32, locked: u32, group: u32) void {
        const state = self.state orelse return;
        _ = xkb.xkb_state_update_mask(state, depressed, latched, locked, 0, 0, group);
    }

    // TODO: this is not spec compliant with the flutter protocol and do not handle repeat events
    //
    //  * Each key press sequence shall consist of one key down event (`kind` being
    //    `kFlutterKeyEventTypeDown`), zero or more repeat events, and one key up
    //    event, representing a physical key button being pressed, held, and
    //    released.
    //  * All events throughout a key press sequence shall have the same `physical`
    //    and `logical`. Having different `character`s is allowed.
    pub fn handleKey(self: *Input, keycode: u32, pressed: bool, time_ms: u32) void {
        const state = self.state orelse return;
        const keymap = self.keymap orelse return;

        _ = xkb.xkb_state_update_key(state, keycode, if (pressed) KEY_DOWN else KEY_UP);

        var plain_keysym: u32 = 0;
        var syms: [*c]const xkb.xkb_keysym_t = null;
        if (xkb.xkb_keymap_key_get_syms_by_level(keymap, keycode, 0, 0, &syms) > 0 and syms != null) {
            plain_keysym = syms[0];
        }

        const codepoint = xkb.xkb_state_key_get_utf32(state, keycode);
        if (pressed) self.text_input.handleKey(plain_keysym, codepoint, true);

        keyboard.send(self.eng, .{
            .keycode = keycode,
            .pressed = pressed,
            .time_ms = time_ms,
            .plain_keysym = plain_keysym,
            .keysym = xkb.xkb_state_key_get_one_sym(state, keycode),
            .codepoint = codepoint,
            .plain_codepoint = xkb.xkb_keysym_to_utf32(plain_keysym),
            .modifiers = modifierMask(state),
        });
    }

    pub fn pointerEnter(self: *Input, surface: ?*wl.Surface, x: f64, y: f64) void {
        if (self.viewForSurface(surface)) |view_id| self.pointer_view = view_id;
        self.mouse_x = x;
        self.mouse_y = y;
        self.sendPointer(c.kAdd, 0, 0, 0, c.kFlutterPointerSignalKindNone);
    }

    pub fn pointerLeave(self: *Input) void {
        self.sendPointer(c.kRemove, 0, 0, 0, c.kFlutterPointerSignalKindNone);
    }

    pub fn pointerMotion(self: *Input, x: f64, y: f64, time_ms: u32) void {
        self.mouse_x = x;
        self.mouse_y = y;
        const phase: c_int = if (self.buttons & c.kFlutterPointerButtonMousePrimary != 0) c.kMove else c.kHover;
        self.sendPointer(phase, time_ms, 0, 0, c.kFlutterPointerSignalKindNone);
    }

    pub fn pointerButton(self: *Input, button: u32, pressed: bool, time_ms: u32) void {
        const flutter_button: i64 = switch (button) {
            0x110 => c.kFlutterPointerButtonMousePrimary, // BTN_LEFT
            0x111 => c.kFlutterPointerButtonMouseSecondary, // BTN_RIGHT
            0x112 => c.kFlutterPointerButtonMouseMiddle, // BTN_MIDDLE
            0x113 => c.kFlutterPointerButtonMouseBack, // BTN_SIDE
            0x114 => c.kFlutterPointerButtonMouseForward, // BTN_EXTRA
            else => 0,
        };
        if (flutter_button == 0) return;

        const before = self.buttons;
        const after = if (pressed) before | flutter_button else before & ~flutter_button;
        if (after == before) return;
        self.buttons = after;

        const phase: c_int = if (after == 0) c.kUp else if (before == 0) c.kDown else c.kMove;
        self.sendPointer(phase, time_ms, 0, 0, c.kFlutterPointerSignalKindNone);
    }

    pub fn pointerAxis(self: *Input, vertical: bool, value: f64, time_ms: u32) void {
        const dx = if (vertical) 0.0 else value;
        const dy = if (vertical) value else 0.0;
        const phase: c_int = if (self.buttons & c.kFlutterPointerButtonMousePrimary != 0) c.kMove else c.kHover;
        self.sendPointer(phase, time_ms, dx, dy, c.kFlutterPointerSignalKindScroll);
    }

    fn sendPointer(self: *Input, phase: c_int, time_ms: u32, scroll_dx: f64, scroll_dy: f64, signal_kind: c_int) void {
        const event = c.FlutterPointerEvent{
            .struct_size = @sizeOf(c.FlutterPointerEvent),
            .phase = @intCast(phase),
            .timestamp = @as(usize, time_ms) * 1000,
            .x = self.mouse_x,
            .y = self.mouse_y,
            .device = self.device,
            .signal_kind = @intCast(signal_kind),
            .scroll_delta_x = scroll_dx,
            .scroll_delta_y = scroll_dy,
            .device_kind = @intCast(c.kFlutterPointerDeviceKindMouse),
            .buttons = self.buttons,
            .pan_x = 0,
            .pan_y = 0,
            .scale = 0,
            .rotation = 0,
            .view_id = self.pointer_view,
            .pressure = 0,
            .pressure_min = 0,
            .pressure_max = 0,
        };
        self.eng.sendPointerEvent(&event);
    }
};
