const std = @import("std");

const c = @import("flutter");
const engine = @import("../engine.zig");
const channels = @import("channels.zig");
const keycodes = @import("keycodes.zig");

/// The Flutter-facing values derived from a single Wayland key event. The
/// platform layer (xkb) owns producing these; this module only translates them
/// into Flutter's protocol.
pub const KeyInfo = struct {
    /// XKB keycode (evdev code + 8).
    keycode: u32,
    pressed: bool,
    time_ms: u32,
    /// Level-0 (unshifted) keysym.
    plain_keysym: u32,
    /// Level-affected keysym, reported as the GTK `keyCode`.
    keysym: u32,
    /// Level-affected code point, or 0 when the key produced no character.
    codepoint: u32,
    /// Level-0 code point, reported as `unicodeScalarValues`.
    plain_codepoint: u32,
    /// GDK-style modifier mask.
    modifiers: u32,
};

/// Send a key event to the framework.
///
/// Two messages are needed: the modern `FlutterKeyEvent` (KeyData) and the
/// legacy raw key event on `flutter/keyevent`. The framework buffers the former
/// and only dispatches it once the matching raw event arrives.
pub fn send(eng: *engine.Engine, info: KeyInfo) void {
    sendKeyEvent(eng, info);
    sendRawKeyEvent(eng, info);
}

fn sendKeyEvent(eng: *engine.Engine, info: KeyInfo) void {
    var event: c.FlutterKeyEvent = .{
        .struct_size = @sizeOf(c.FlutterKeyEvent),
        .timestamp = @floatFromInt(@as(u64, info.time_ms) * 1000),
        .type = if (info.pressed) @intCast(c.kFlutterKeyEventTypeDown) else @intCast(c.kFlutterKeyEventTypeUp),
        // Usage Page (16 bits) | Usage ID (16 bits)
        .physical = keycodes.HID_KEYBOARD_PAGE | keycodes.hid_by_evdev[info.keycode - 8],
        .logical = if (info.plain_keysym != 0) keycodes.keysymToLogical(info.plain_keysym) else 0,
        .character = null,
        .synthesized = false,
        .device_type = @intCast(c.kFlutterKeyEventDeviceTypeKeyboard),
    };

    var char_z: [5]u8 = undefined;
    if (info.pressed and info.codepoint >= 0x20) {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(info.codepoint), &buf) catch 0;
        @memcpy(char_z[0..n], buf[0..n]);
        char_z[n] = 0;
        event.character = @ptrCast(&char_z);
    }

    eng.sendKeyEvent(&event);
}

fn sendRawKeyEvent(eng: *engine.Engine, info: KeyInfo) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &buf,
        "{{\"keymap\":\"linux\",\"toolkit\":\"gtk\",\"unicodeScalarValues\":{d},\"keyCode\":{d},\"scanCode\":{d},\"modifiers\":{d},\"type\":\"{s}\"}}",
        .{ info.plain_codepoint, info.keysym, info.keycode, info.modifiers, if (info.pressed) "keydown" else "keyup" },
    ) catch return;

    eng.sendPlatformMessage(channels.keyevent.name.ptr, msg);
}
