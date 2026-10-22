const std = @import("std");

const builtin = @import("builtin");

/// What the framework asked the pointer to show after a
/// `flutter/mousecursor` activation.
///
/// The shapes are the names `wp_cursor_shape_device_v1` uses, without the
/// dependency on the generated Wayland bindings: this module decodes the wire
/// message, and the Wayland backend maps the result.
pub const Cursor = union(enum) {
    /// `SystemMouseCursors.none`: hide the pointer.
    hidden,
    shape: Shape,

    pub const Shape = enum {
        default,
        context_menu,
        help,
        pointer,
        progress,
        wait,
        cell,
        crosshair,
        text,
        vertical_text,
        alias,
        copy,
        move,
        no_drop,
        not_allowed,
        grab,
        grabbing,
        e_resize,
        n_resize,
        ne_resize,
        nw_resize,
        s_resize,
        se_resize,
        sw_resize,
        w_resize,
        ew_resize,
        ns_resize,
        nesw_resize,
        nwse_resize,
        col_resize,
        row_resize,
        all_scroll,
        zoom_in,
        zoom_out,
    };
};

/// The `kind` names the framework's `SystemMouseCursors` sends, mapped to the
/// shape the compositor draws.
///
/// `disappearing` has no cursor-shape equivalent, and the GTK embedder falls
/// back to the default for it as well. Unknown names (a newer framework, or a
/// custom cursor kind) also become the default rather than leaving the pointer
/// at whatever it showed before.
const cursor_table = std.StaticStringMap(Cursor).initComptime(.{
    .{ "none", Cursor{ .hidden = {} } },
    .{ "basic", Cursor{ .shape = .default } },
    .{ "click", Cursor{ .shape = .pointer } },
    .{ "forbidden", Cursor{ .shape = .not_allowed } },
    .{ "wait", Cursor{ .shape = .wait } },
    .{ "progress", Cursor{ .shape = .progress } },
    .{ "contextMenu", Cursor{ .shape = .context_menu } },
    .{ "help", Cursor{ .shape = .help } },
    .{ "text", Cursor{ .shape = .text } },
    .{ "verticalText", Cursor{ .shape = .vertical_text } },
    .{ "cell", Cursor{ .shape = .cell } },
    .{ "precise", Cursor{ .shape = .crosshair } },
    .{ "move", Cursor{ .shape = .move } },
    .{ "grab", Cursor{ .shape = .grab } },
    .{ "grabbing", Cursor{ .shape = .grabbing } },
    .{ "noDrop", Cursor{ .shape = .no_drop } },
    .{ "alias", Cursor{ .shape = .alias } },
    .{ "copy", Cursor{ .shape = .copy } },
    .{ "disappearing", Cursor{ .shape = .default } },
    .{ "allScroll", Cursor{ .shape = .all_scroll } },
    .{ "resizeLeftRight", Cursor{ .shape = .ew_resize } },
    .{ "resizeUpDown", Cursor{ .shape = .ns_resize } },
    .{ "resizeUpLeftDownRight", Cursor{ .shape = .nwse_resize } },
    .{ "resizeUpRightDownLeft", Cursor{ .shape = .nesw_resize } },
    .{ "resizeUp", Cursor{ .shape = .n_resize } },
    .{ "resizeDown", Cursor{ .shape = .s_resize } },
    .{ "resizeLeft", Cursor{ .shape = .w_resize } },
    .{ "resizeRight", Cursor{ .shape = .e_resize } },
    .{ "resizeUpLeft", Cursor{ .shape = .nw_resize } },
    .{ "resizeUpRight", Cursor{ .shape = .ne_resize } },
    .{ "resizeDownLeft", Cursor{ .shape = .sw_resize } },
    .{ "resizeDownRight", Cursor{ .shape = .se_resize } },
    .{ "resizeColumn", Cursor{ .shape = .col_resize } },
    .{ "resizeRow", Cursor{ .shape = .row_resize } },
    .{ "zoomIn", Cursor{ .shape = .zoom_in } },
    .{ "zoomOut", Cursor{ .shape = .zoom_out } },
});

/// The cursor a Flutter `kind` asks for. Unknown kinds (and `disappearing`)
/// fall back to the default shape.
pub fn cursorFor(kind: []const u8) Cursor {
    return cursor_table.get(kind) orelse blk: {
        std.debug.print("fembed: no cursor found for {s}\n", .{kind});
        break: blk Cursor{ .shape = .default };
    };
}

/// Decode the arguments of an `activateSystemCursor` call from a
/// `StandardMethodCodec` method-call message.
///
/// Returns null when this is not that method or the message cannot be decoded.
/// A valid call without a `kind` entry asks for the default cursor, which is
/// what the GTK embedder does too.
pub fn decode(data: []const u8) ?Cursor {
    var reader = Reader{ .bytes = data };

    const method = reader.readString() catch return null;
    if (!std.mem.eql(u8, method, "activateSystemCursor")) return null;

    const kind = reader.readArgsKind() catch return null;
    return if (kind) |value| cursorFor(value) else Cursor{ .shape = .default };
}

const endian = builtin.cpu.arch.endian();

const DecodeError = error{
    Truncated,
    NotAString,
    UnsupportedValue,
    TooDeep,
};

/// The subset of `StandardMessageCodec` needed to read the cursor channel's
/// arguments: strings, the expanding length format, and enough of a value
/// skipper to ignore arguments this embedder does not care about (`device`,
/// and anything a newer framework adds).
const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn readByte(self: *Reader) DecodeError!u8 {
        if (self.pos >= self.bytes.len) return error.Truncated;
        defer self.pos += 1;
        return self.bytes[self.pos];
    }

    fn readBytes(self: *Reader, len: usize) DecodeError![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.Truncated;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn readU16(self: *Reader) DecodeError!u16 {
        const bytes = try self.readBytes(2);
        return std.mem.readInt(u16, bytes[0..2], endian);
    }

    fn readU32(self: *Reader) DecodeError!u32 {
        const bytes = try self.readBytes(4);
        return std.mem.readInt(u32, bytes[0..4], endian);
    }

    /// The expanding length format `StandardMessageCodec` uses for strings,
    /// lists and maps.
    fn readSize(self: *Reader) DecodeError!u32 {
        const first = try self.readByte();
        return switch (first) {
            254 => try self.readU16(),
            255 => try self.readU32(),
            else => first,
        };
    }

    /// A length-prefixed string body, after its type byte.
    fn readStringBody(self: *Reader) DecodeError![]const u8 {
        const len = try self.readSize();
        return self.readBytes(len);
    }

    /// A complete string value, including its type byte.
    fn readString(self: *Reader) DecodeError![]const u8 {
        if (try self.readByte() != 7) return error.NotAString;
        return self.readStringBody();
    }

    /// Return the `kind` argument of the method's argument map, or null if the
    /// arguments are not a map or have no string `kind`.
    fn readArgsKind(self: *Reader) DecodeError!?[]const u8 {
        // `args` can be omitted (encoded as null) for a call without arguments.
        if (try self.readByte() != 13) return null;

        const count = try self.readSize();
        var kind: ?[]const u8 = null;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const key = try self.readString();
            const type_byte = try self.readByte();

            if (std.mem.eql(u8, key, "kind")) {
                if (type_byte == 7) {
                    kind = try self.readStringBody();
                } else {
                    try self.skipValue(type_byte, 0);
                }
            } else {
                try self.skipValue(type_byte, 0);
            }
        }
        return kind;
    }

    /// Consume one encoded value. Typed lists (8-11 and 14) are not produced
    /// by this channel; refusing them is safer than getting their alignment
    /// and element size rules wrong.
    fn skipValue(self: *Reader, type_byte: u8, depth: u8) DecodeError!void {
        if (depth >= 32) return error.TooDeep;

        switch (type_byte) {
            // null, true, false
            0, 1, 2 => {},
            // int32
            3 => _ = try self.readBytes(4),
            // int64, float64
            4, 6 => _ = try self.readBytes(8),
            // string (and the JS-only large integer, which uses the string layout)
            5, 7 => _ = try self.readStringBody(),
            // heterogeneous list
            12 => {
                const count = try self.readSize();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try self.skipValue(try self.readByte(), depth + 1);
                }
            },
            // heterogeneous map
            13 => {
                const count = try self.readSize();
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    try self.skipValue(try self.readByte(), depth + 1);
                    try self.skipValue(try self.readByte(), depth + 1);
                }
            },
            else => return error.UnsupportedValue,
        }
    }
};

fn appendSize(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, value: u32) !void {
    if (value < 254) {
        try out.append(gpa, @intCast(value));
    } else if (value <= 0xffff) {
        try out.append(gpa, 254);
        try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u16, @intCast(value), endian)));
    } else {
        try out.append(gpa, 255);
        try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(u32, value, endian)));
    }
}

fn appendString(out: *std.ArrayListUnmanaged(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try out.append(gpa, 7);
    try appendSize(out, gpa, @intCast(value.len));
    try out.appendSlice(gpa, value);
}

fn testCall(gpa: std.mem.Allocator, method: []const u8, kind: ?[]const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    try appendString(&out, gpa, method);
    try out.append(gpa, 13);
    try appendSize(&out, gpa, if (kind == null) 1 else 2);

    try appendString(&out, gpa, "device");
    try out.append(gpa, 3);
    try out.appendSlice(gpa, std.mem.asBytes(&std.mem.nativeTo(i32, 1, endian)));

    if (kind) |value| {
        try appendString(&out, gpa, "kind");
        try appendString(&out, gpa, value);
    }
    return out.toOwnedSlice(gpa);
}

test "activateSystemCursor decodes the kind and ignores the device" {
    const testing = std.testing;

    const data = try testCall(testing.allocator, "activateSystemCursor", "click");
    defer testing.allocator.free(data);

    const cursor = decode(data).?;
    try testing.expectEqual(Cursor.Shape.pointer, cursor.shape);
}

test "unknown method names and truncated messages decode to null" {
    const testing = std.testing;

    const other = try testCall(testing.allocator, "somethingElse", "click");
    defer testing.allocator.free(other);
    try testing.expectEqual(@as(?Cursor, null), decode(other));

    const click = try testCall(testing.allocator, "activateSystemCursor", "click");
    defer testing.allocator.free(click);
    try testing.expectEqual(@as(?Cursor, null), decode(click[0 .. click.len - 1]));
}

test "every framework cursor name maps to a shape" {
    const testing = std.testing;
    const cases = [_]struct { []const u8, Cursor }{
        .{ "none", Cursor{ .hidden = {} } },
        .{ "basic", Cursor{ .shape = .default } },
        .{ "click", Cursor{ .shape = .pointer } },
        .{ "forbidden", Cursor{ .shape = .not_allowed } },
        .{ "wait", Cursor{ .shape = .wait } },
        .{ "progress", Cursor{ .shape = .progress } },
        .{ "contextMenu", Cursor{ .shape = .context_menu } },
        .{ "help", Cursor{ .shape = .help } },
        .{ "text", Cursor{ .shape = .text } },
        .{ "verticalText", Cursor{ .shape = .vertical_text } },
        .{ "cell", Cursor{ .shape = .cell } },
        .{ "precise", Cursor{ .shape = .crosshair } },
        .{ "move", Cursor{ .shape = .move } },
        .{ "grab", Cursor{ .shape = .grab } },
        .{ "grabbing", Cursor{ .shape = .grabbing } },
        .{ "noDrop", Cursor{ .shape = .no_drop } },
        .{ "alias", Cursor{ .shape = .alias } },
        .{ "copy", Cursor{ .shape = .copy } },
        .{ "disappearing", Cursor{ .shape = .default } },
        .{ "allScroll", Cursor{ .shape = .all_scroll } },
        .{ "resizeLeftRight", Cursor{ .shape = .ew_resize } },
        .{ "resizeUpDown", Cursor{ .shape = .ns_resize } },
        .{ "resizeUpLeftDownRight", Cursor{ .shape = .nwse_resize } },
        .{ "resizeUpRightDownLeft", Cursor{ .shape = .nesw_resize } },
        .{ "resizeUp", Cursor{ .shape = .n_resize } },
        .{ "resizeDown", Cursor{ .shape = .s_resize } },
        .{ "resizeLeft", Cursor{ .shape = .w_resize } },
        .{ "resizeRight", Cursor{ .shape = .e_resize } },
        .{ "resizeUpLeft", Cursor{ .shape = .nw_resize } },
        .{ "resizeUpRight", Cursor{ .shape = .ne_resize } },
        .{ "resizeDownLeft", Cursor{ .shape = .sw_resize } },
        .{ "resizeDownRight", Cursor{ .shape = .se_resize } },
        .{ "resizeColumn", Cursor{ .shape = .col_resize } },
        .{ "resizeRow", Cursor{ .shape = .row_resize } },
        .{ "zoomIn", Cursor{ .shape = .zoom_in } },
        .{ "zoomOut", Cursor{ .shape = .zoom_out } },
    };

    for (cases) |case| {
        try testing.expectEqual(case[1], cursorFor(case[0]));
    }
    try testing.expectEqual(Cursor{ .shape = .default }, cursorFor("unknown"));
}
