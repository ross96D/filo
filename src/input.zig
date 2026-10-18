const std = @import("std");

const c = @import("flutter");
const xkb = @import("xkb");
const engine = @import("engine.zig");

const CONTEXT_NO_FLAGS: xkb.enum_xkb_context_flags = @intCast(xkb.XKB_CONTEXT_NO_FLAGS);
const KEYMAP_FORMAT_TEXT_V1: xkb.enum_xkb_keymap_format = @intCast(xkb.XKB_KEYMAP_FORMAT_TEXT_V1);
const KEYMAP_COMPILE_NO_FLAGS: xkb.enum_xkb_keymap_compile_flags = @intCast(xkb.XKB_KEYMAP_COMPILE_NO_FLAGS);
const KEY_DOWN: xkb.enum_xkb_key_direction = @intCast(xkb.XKB_KEY_DOWN);
const KEY_UP: xkb.enum_xkb_key_direction = @intCast(xkb.XKB_KEY_UP);

/// USB HID usage page 0x07 (Keyboard/Keypad). Flutter's `physical` key IDs are
/// full USB HID usage codes (`page << 16 | usage`), e.g. keyA = 0x00070004.
/// See `FlutterKeyEvent.physical` in flutter_embedder.h and
/// `PhysicalKeyboardKey` in the framework's keyboard_key.g.dart.
const HID_KEYBOARD_PAGE: u64 = 0x00070000;

/// Flutter logical key ID planes. A logical key ID is `plane | value`; see
/// `LogicalKeyboardKey` in the framework's keyboard_key.g.dart for the
/// authoritative definitions.
const LOGICAL_UNICODE_PLANE: u64 = 0x00000000000;
const LOGICAL_UNPRINTABLE_PLANE: u64 = 0x00100000000;
const LOGICAL_FLUTTER_PLANE: u64 = 0x00200000000;
const LOGICAL_GTK_PLANE: u64 = 0x01500000000;

/// Linux (evdev) keycodes to USB HID usage values. See
/// linux/input-event-codes.h and the USB HID Usage Tables (keyboard page).
/// Linux keycodes follow the AT scan-code layout, not alphabetical order.
const hid_by_evdev: [256]u8 = blk: {
    var t: [256]u8 = @splat(0);
    const map = [_]struct { evdev: u32, hid: u64 }{
        .{ .evdev = 16, .hid = 20 }, // q
        .{ .evdev = 17, .hid = 26 }, // w
        .{ .evdev = 18, .hid = 8 }, // e
        .{ .evdev = 19, .hid = 21 }, // r
        .{ .evdev = 20, .hid = 23 }, // t
        .{ .evdev = 21, .hid = 28 }, // y
        .{ .evdev = 22, .hid = 24 }, // u
        .{ .evdev = 23, .hid = 12 }, // i
        .{ .evdev = 24, .hid = 18 }, // o
        .{ .evdev = 25, .hid = 19 }, // p
        .{ .evdev = 30, .hid = 4 }, // a
        .{ .evdev = 31, .hid = 22 }, // s
        .{ .evdev = 32, .hid = 7 }, // d
        .{ .evdev = 33, .hid = 9 }, // f
        .{ .evdev = 34, .hid = 10 }, // g
        .{ .evdev = 35, .hid = 11 }, // h
        .{ .evdev = 36, .hid = 13 }, // j
        .{ .evdev = 37, .hid = 14 }, // k
        .{ .evdev = 38, .hid = 15 }, // l
        .{ .evdev = 44, .hid = 29 }, // z
        .{ .evdev = 45, .hid = 27 }, // x
        .{ .evdev = 46, .hid = 6 }, // c
        .{ .evdev = 47, .hid = 25 }, // v
        .{ .evdev = 48, .hid = 5 }, // b
        .{ .evdev = 49, .hid = 17 }, // n
        .{ .evdev = 50, .hid = 16 }, // m
        .{ .evdev = 2, .hid = 30 }, // 1
        .{ .evdev = 3, .hid = 31 }, // 2
        .{ .evdev = 4, .hid = 32 }, // 3
        .{ .evdev = 5, .hid = 33 }, // 4
        .{ .evdev = 6, .hid = 34 }, // 5
        .{ .evdev = 7, .hid = 35 }, // 6
        .{ .evdev = 8, .hid = 36 }, // 7
        .{ .evdev = 9, .hid = 37 }, // 8
        .{ .evdev = 10, .hid = 38 }, // 9
        .{ .evdev = 11, .hid = 39 }, // 0
        .{ .evdev = 1, .hid = 41 }, // esc
        .{ .evdev = 12, .hid = 45 }, // minus
        .{ .evdev = 13, .hid = 46 }, // equal
        .{ .evdev = 14, .hid = 42 }, // backspace
        .{ .evdev = 15, .hid = 43 }, // tab
        .{ .evdev = 26, .hid = 47 }, // leftbrace
        .{ .evdev = 27, .hid = 48 }, // rightbrace
        .{ .evdev = 28, .hid = 40 }, // enter
        .{ .evdev = 29, .hid = 224 }, // leftctrl
        .{ .evdev = 39, .hid = 51 }, // semicolon
        .{ .evdev = 40, .hid = 52 }, // apostrophe
        .{ .evdev = 41, .hid = 53 }, // grave
        .{ .evdev = 42, .hid = 225 }, // leftshift
        .{ .evdev = 43, .hid = 49 }, // backslash
        .{ .evdev = 51, .hid = 54 }, // comma
        .{ .evdev = 52, .hid = 55 }, // dot
        .{ .evdev = 53, .hid = 56 }, // slash
        .{ .evdev = 54, .hid = 229 }, // rightshift
        .{ .evdev = 56, .hid = 226 }, // leftalt
        .{ .evdev = 57, .hid = 44 }, // space
        .{ .evdev = 58, .hid = 57 }, // capslock
        .{ .evdev = 97, .hid = 228 }, // rightctrl
        .{ .evdev = 100, .hid = 230 }, // rightalt
        .{ .evdev = 125, .hid = 227 }, // leftmeta
        .{ .evdev = 126, .hid = 231 }, // rightmeta
        .{ .evdev = 59, .hid = 58 }, // f1
        .{ .evdev = 60, .hid = 59 },
        .{ .evdev = 61, .hid = 60 },
        .{ .evdev = 62, .hid = 61 },
        .{ .evdev = 63, .hid = 62 },
        .{ .evdev = 64, .hid = 63 },
        .{ .evdev = 65, .hid = 64 },
        .{ .evdev = 66, .hid = 65 },
        .{ .evdev = 67, .hid = 66 },
        .{ .evdev = 68, .hid = 67 },
        .{ .evdev = 87, .hid = 68 }, // f11
        .{ .evdev = 88, .hid = 69 }, // f12
        .{ .evdev = 102, .hid = 74 }, // home
        .{ .evdev = 103, .hid = 82 }, // up
        .{ .evdev = 104, .hid = 75 }, // pageup
        .{ .evdev = 105, .hid = 80 }, // left
        .{ .evdev = 106, .hid = 79 }, // right
        .{ .evdev = 107, .hid = 77 }, // end
        .{ .evdev = 108, .hid = 81 }, // down
        .{ .evdev = 109, .hid = 78 }, // pagedown
        .{ .evdev = 110, .hid = 73 }, // insert
        .{ .evdev = 111, .hid = 76 }, // delete
        .{ .evdev = 69, .hid = 83 }, // numlock
        .{ .evdev = 70, .hid = 71 }, // scrolllock
    };
    for (map) |e| t[e.evdev] = e.hid;
    break :blk t;
};

/// Map a level-0 (unshifted) XKB keysym to a Flutter logical key ID.
fn keysymToLogical(keysym: u32) u64 {
    if (keysym >= 0x20 and keysym <= 0x7e) return LOGICAL_UNICODE_PLANE | keysym;
    if (keysym >= 0xa0 and keysym <= 0xff) return LOGICAL_UNICODE_PLANE | keysym;
    return switch (keysym) {
        @intCast(xkb.XKB_KEY_Return) => LOGICAL_UNPRINTABLE_PLANE | 0x00d,
        @intCast(xkb.XKB_KEY_Escape) => LOGICAL_UNPRINTABLE_PLANE | 0x01b,
        @intCast(xkb.XKB_KEY_BackSpace) => LOGICAL_UNPRINTABLE_PLANE | 0x008,
        @intCast(xkb.XKB_KEY_Tab) => LOGICAL_UNPRINTABLE_PLANE | 0x009,
        @intCast(xkb.XKB_KEY_Delete) => LOGICAL_UNPRINTABLE_PLANE | 0x07f,
        @intCast(xkb.XKB_KEY_Insert) => LOGICAL_UNPRINTABLE_PLANE | 0x407,
        @intCast(xkb.XKB_KEY_Home) => LOGICAL_UNPRINTABLE_PLANE | 0x306,
        @intCast(xkb.XKB_KEY_End) => LOGICAL_UNPRINTABLE_PLANE | 0x305,
        @intCast(xkb.XKB_KEY_Page_Up) => LOGICAL_UNPRINTABLE_PLANE | 0x308,
        @intCast(xkb.XKB_KEY_Page_Down) => LOGICAL_UNPRINTABLE_PLANE | 0x307,
        @intCast(xkb.XKB_KEY_Up) => LOGICAL_UNPRINTABLE_PLANE | 0x304,
        @intCast(xkb.XKB_KEY_Down) => LOGICAL_UNPRINTABLE_PLANE | 0x301,
        @intCast(xkb.XKB_KEY_Left) => LOGICAL_UNPRINTABLE_PLANE | 0x302,
        @intCast(xkb.XKB_KEY_Right) => LOGICAL_UNPRINTABLE_PLANE | 0x303,
        @intCast(xkb.XKB_KEY_Shift_L) => LOGICAL_FLUTTER_PLANE | 0x102,
        @intCast(xkb.XKB_KEY_Shift_R) => LOGICAL_FLUTTER_PLANE | 0x103,
        @intCast(xkb.XKB_KEY_Control_L) => LOGICAL_FLUTTER_PLANE | 0x100,
        @intCast(xkb.XKB_KEY_Control_R) => LOGICAL_FLUTTER_PLANE | 0x101,
        @intCast(xkb.XKB_KEY_Alt_L) => LOGICAL_FLUTTER_PLANE | 0x104,
        @intCast(xkb.XKB_KEY_Alt_R) => LOGICAL_FLUTTER_PLANE | 0x105,
        @intCast(xkb.XKB_KEY_Super_L) => LOGICAL_FLUTTER_PLANE | 0x106,
        @intCast(xkb.XKB_KEY_Super_R) => LOGICAL_FLUTTER_PLANE | 0x107,
        @intCast(xkb.XKB_KEY_Caps_Lock) => LOGICAL_UNPRINTABLE_PLANE | 0x104,
        @intCast(xkb.XKB_KEY_F1) => LOGICAL_UNPRINTABLE_PLANE | 0x801,
        @intCast(xkb.XKB_KEY_F2) => LOGICAL_UNPRINTABLE_PLANE | 0x802,
        @intCast(xkb.XKB_KEY_F3) => LOGICAL_UNPRINTABLE_PLANE | 0x803,
        @intCast(xkb.XKB_KEY_F4) => LOGICAL_UNPRINTABLE_PLANE | 0x804,
        @intCast(xkb.XKB_KEY_F5) => LOGICAL_UNPRINTABLE_PLANE | 0x805,
        @intCast(xkb.XKB_KEY_F6) => LOGICAL_UNPRINTABLE_PLANE | 0x806,
        @intCast(xkb.XKB_KEY_F7) => LOGICAL_UNPRINTABLE_PLANE | 0x807,
        @intCast(xkb.XKB_KEY_F8) => LOGICAL_UNPRINTABLE_PLANE | 0x808,
        @intCast(xkb.XKB_KEY_F9) => LOGICAL_UNPRINTABLE_PLANE | 0x809,
        @intCast(xkb.XKB_KEY_F10) => LOGICAL_UNPRINTABLE_PLANE | 0x80a,
        @intCast(xkb.XKB_KEY_F11) => LOGICAL_UNPRINTABLE_PLANE | 0x80b,
        @intCast(xkb.XKB_KEY_F12) => LOGICAL_UNPRINTABLE_PLANE | 0x80c,
        else => LOGICAL_GTK_PLANE | keysym,
    };
}

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

fn utf8Encode(codepoint: u32, buf: *[4]u8) usize {
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return 1;
    } else if (codepoint < 0x800) {
        buf[0] = @intCast(0xc0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3f));
        return 2;
    } else if (codepoint < 0x10000) {
        buf[0] = @intCast(0xe0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        buf[2] = @intCast(0x80 | (codepoint & 0x3f));
        return 3;
    } else {
        buf[0] = @intCast(0xf0 | (codepoint >> 18));
        buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3f));
        buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3f));
        buf[3] = @intCast(0x80 | (codepoint & 0x3f));
        return 4;
    }
}

pub const Input = struct {
    eng: *engine.Engine,
    xkb_ctx: ?*xkb.xkb_context,
    keymap: ?*xkb.xkb_keymap,
    state: ?*xkb.xkb_state,
    mouse_x: f64,
    mouse_y: f64,
    buttons: i64,
    device: i32,

    pub fn init(eng: *engine.Engine) !Input {
        const ctx = xkb.xkb_context_new(CONTEXT_NO_FLAGS) orelse return error.XkbContextFailed;
        return .{
            .eng = eng,
            .xkb_ctx = ctx,
            .keymap = null,
            .state = null,
            .mouse_x = 0,
            .mouse_y = 0,
            .buttons = 0,
            .device = 0,
        };
    }

    pub fn deinit(self: *Input) void {
        if (self.state) |s| xkb.xkb_state_unref(s);
        if (self.keymap) |k| xkb.xkb_keymap_unref(k);
        if (self.xkb_ctx) |ctx| xkb.xkb_context_unref(ctx);
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
            std.debug.print("fembed: failed to compile xkb keymap\n", .{});
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

        var event: c.FlutterKeyEvent = .{
            .struct_size = @sizeOf(c.FlutterKeyEvent),
            .timestamp = @floatFromInt(@as(u64, time_ms) * 1000),
            .type = if (pressed) @intCast(c.kFlutterKeyEventTypeDown) else @intCast(c.kFlutterKeyEventTypeUp),
            // Usage Page (16 bits)  | Usage ID (16 bits)
            .physical = HID_KEYBOARD_PAGE | hid_by_evdev[keycode - 8],
            .logical = 0,
            .character = null,
            .synthesized = false,
            .device_type = @intCast(c.kFlutterKeyEventDeviceTypeKeyboard),
        };

        var syms: [*c]const xkb.xkb_keysym_t = null;
        var plain_keysym: u32 = 0;
        if (xkb.xkb_keymap_key_get_syms_by_level(keymap, keycode, 0, 0, &syms) > 0 and syms != null) {
            plain_keysym = syms[0];
            event.logical = keysymToLogical(plain_keysym);
        }

        var char_z: [5]u8 = undefined;
        if (pressed) {
            const codepoint = xkb.xkb_state_key_get_utf32(state, keycode);
            if (codepoint != 0 and codepoint >= 0x20) {
                var buf: [4]u8 = undefined;
                const n = utf8Encode(codepoint, &buf);
                @memcpy(char_z[0..n], buf[0..n]);
                char_z[n] = 0;
                event.character = @ptrCast(&char_z);
            }
        }

        self.eng.sendKeyEvent(&event);
        self.sendRawKeyEvent(keycode, plain_keysym, pressed);
    }

    /// Send the legacy raw key event on flutter/keyevent. The framework buffers
    /// the KeyData sent above and only dispatches it once a matching raw key
    /// event arrives, so both must be sent for keyboard input to work.
    fn sendRawKeyEvent(self: *Input, keycode: u32, plain_keysym: u32, pressed: bool) void {
        const state = self.state orelse return;

        const keysym: u32 = xkb.xkb_state_key_get_one_sym(state, keycode);
        const plain_codepoint: u32 = xkb.xkb_keysym_to_utf32(plain_keysym);
        const modifiers: u32 = modifierMask(state);

        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "{{\"keymap\":\"linux\",\"toolkit\":\"gtk\",\"unicodeScalarValues\":{d},\"keyCode\":{d},\"scanCode\":{d},\"modifiers\":{d},\"type\":\"{s}\"}}",
            .{ plain_codepoint, keysym, keycode, modifiers, if (pressed) "keydown" else "keyup" },
        ) catch return;

        self.eng.sendPlatformMessage("flutter/keyevent", msg);
    }

    pub fn pointerEnter(self: *Input, x: f64, y: f64) void {
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
            .view_id = 0,
            .pressure = 0,
            .pressure_min = 0,
            .pressure_max = 0,
        };
        self.eng.sendPointerEvent(&event);
    }
};
