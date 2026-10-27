const std = @import("std");

const channels = @import("channels.zig");

/// A successful `JSONMethodCodec` reply: a one-element list whose element is
/// null (`JSONMethodCodec` envelopes are always lists).
pub const json_success: []const u8 = "[null]";

/// Stand-in for the arguments of a method call that takes none: the framework
/// omits `args` for those, which reads the same as a JSON null.
pub const no_args: std.json.Value = .null;

/// A successful `JSONMessageCodec` reply: a bare JSON value.
pub const json_null: []const u8 = "null";

/// A successful `StandardMessageCodec` reply: a single standard-encoded null.
pub const standard_message_success: []const u8 = &.{0x00};

/// A successful `StandardMethodCodec` reply: the success marker (0x00)
/// followed by a standard-encoded null.
pub const standard_method_success: []const u8 = &.{ 0x00, 0x00 };

const error_fallback: []const u8 = "[\"error\",\"error\",null]";

/// Format a `JSONMethodCodec` error envelope: `[code, message, details]`.
/// `buf` must stay alive until the reply has been sent.
pub fn jsonError(buf: []u8, code: []const u8, message: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "[\"{s}\",\"{s}\",null]", .{ code, message }) catch error_fallback;
}

/// A benign success reply for a channel we do not implement, encoded with that
/// channel's codec so the framework can decode it.
pub fn defaultReply(codec: channels.Codec) []const u8 {
    return switch (codec) {
        .json_method => json_success,
        .json_message => json_null,
        .standard_method => standard_method_success,
        .standard_message => standard_message_success,
    };
}

/// Append `n` to `out` as a JSON number.
pub fn appendNum(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, n: i64) !void {
    var buf: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{n});
    try out.appendSlice(gpa, s);
}

/// Append `s` to `out` as a JSON string, escaping the characters JSON requires.
///
/// The result is always valid UTF-8: bytes that are not part of a well-formed
/// sequence are replaced with U+FFFD. That matters for clipboard text, which
/// can arrive in a non-UTF-8 flavour (X11 `STRING`/`TEXT` are Latin-1).
pub fn appendJsonString(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, s: []const u8) !void {
    const hex = "0123456789abcdef";
    const replacement = "\u{fffd}";

    try out.append(gpa, '"');
    var i: usize = 0;
    while (i < s.len) {
        // Decode one scalar value; on any malformed byte emit U+FFFD and move
        // on by a single byte so the rest of the input still gets a chance.
        var codepoint: u21 = 0xfffd;
        var size: usize = 1;
        if (s[i] < 0x80) {
            codepoint = s[i];
        } else if (std.unicode.utf8ByteSequenceLength(s[i])) |len| {
            if (len > 1 and i + len <= s.len) {
                if (std.unicode.utf8Decode(s[i..][0..len])) |decoded| {
                    codepoint = decoded;
                    size = len;
                } else |_| {}
            }
        } else |_| {}

        switch (codepoint) {
            '"' => try out.appendSlice(gpa, "\\\""),
            '\\' => try out.appendSlice(gpa, "\\\\"),
            '\n' => try out.appendSlice(gpa, "\\n"),
            '\r' => try out.appendSlice(gpa, "\\r"),
            '\t' => try out.appendSlice(gpa, "\\t"),
            0x08 => try out.appendSlice(gpa, "\\b"),
            0x0c => try out.appendSlice(gpa, "\\f"),
            else => {
                if (codepoint < 0x20) {
                    try out.appendSlice(gpa, &.{ '\\', 'u', '0', '0', hex[@intCast(codepoint >> 4)], hex[@intCast(codepoint & 0xf)] });
                } else if (size == 1 and s[i] >= 0x80) {
                    try out.appendSlice(gpa, replacement);
                } else {
                    try out.appendSlice(gpa, s[i..][0..size]);
                }
            },
        }
        i += size;
    }
    try out.append(gpa, '"');
}

test "JSON strings escape and reject malformed UTF-8" {
    const testing = std.testing;
    const gpa = testing.allocator;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(gpa);

    try appendJsonString(&out, gpa, "a\"b\\c\nd\te\x01f");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\te\\u0001f\"", out.items);

    out.clearRetainingCapacity();
    try appendJsonString(&out, gpa, "h\u{e9}llo \u{1f600}");
    try testing.expectEqualStrings("\"h\u{e9}llo \u{1f600}\"", out.items);

    out.clearRetainingCapacity();
    try appendJsonString(&out, gpa, "bad\xffbyte");
    try testing.expectEqualStrings("\"bad\u{fffd}byte\"", out.items);
}
