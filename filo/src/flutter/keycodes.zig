const xkb = @import("xkb");

/// USB HID usage page 0x07 (Keyboard/Keypad). Flutter's `physical` key IDs are
/// full USB HID usage codes (`page << 16 | usage`), e.g. keyA = 0x00070004.
/// See `FlutterKeyEvent.physical` in flutter_embedder.h and
/// `PhysicalKeyboardKey` in the framework's keyboard_key.g.dart.
pub const HID_KEYBOARD_PAGE: u64 = 0x00070000;

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
pub const hid_by_evdev: [256]u8 = blk: {
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
pub fn keysymToLogical(keysym: u32) u64 {
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
