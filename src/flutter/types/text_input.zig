//! Zig mirrors of the value types exchanged over the `flutter/textinput`
//! channel.
//!
//! These are ports of the Dart types in the framework's
//! `packages/flutter/lib/src/services/text_input.dart`, plus the few types from
//! `services/text_editing.dart` and `dart:ui` that those embed, restricted to
//! the ones that actually cross the channel. Only the data and the `fromJson`
//! decoders are ported; `toJson` is not here yet, because the embedder only
//! sends a handful of those messages and they are written one at a time.
//!
//! Field names mirror the Dart fields, and therefore the JSON keys, rather than
//! Zig's snake_case convention: a field and its wire name are then trivially
//! related. Enum tags mirror the Dart member names too, since the wire form is
//! usually either the index or `toString()`.
//!
//! Offsets (`TextRange`, `TextSelection`, `SelectionRect.position`) are in the
//! framework's units, i.e. UTF-16 code units, *not* bytes: do not index into a
//! UTF-8 buffer with them. Strings are borrowed views into the decoded message.
//! The only thing `fromJson` allocates is the list fields (`allowedMimeTypes`,
//! `hintLocales`, `autofillHints`), which the structs that own them free in
//! `deinit`; everything else is a view into the `std.json.Value` passed in, so
//! that value must outlive the struct.
//!
//! `fromJson` mirrors the Dart `fromJSON` constructors where the framework has
//! them. A field that is absent, or JSON null, falls back to the Dart default;
//! a field that is present with a type or spelling the framework never sends is
//! an error, so protocol drift shows up at the parse site rather than as a
//! silently wrong default.
//!
//! Not ported, because they live in other services: `TextEditingDelta`
//! (`services/text_editing_delta.dart`, the opt-in delta model behind
//! `enableDeltaModel`) and `KeyboardInsertedContent`
//! (`services/keyboard_inserted_content.dart`). `Locale` (`dart:ui`) is not
//! ported either: `hintLocales` is modelled as language tags, which is what the
//! channel sends.

const std = @import("std");

// ---------------------------------------------------------------------------
// JSON decoding
// ---------------------------------------------------------------------------

/// Why a `fromJson` failed. The message is decoded once with the `std.json`
/// parser and handed around as its `std.json.Value` tree, so a wrong value
/// (rather than unparseable text) is what gets reported here.
pub const Error = error{
    /// The value has the wrong shape: a string where the framework always
    /// sends an object, an array that is too short, and so on.
    InvalidJson,
    /// The value has the right shape but carries something the framework never
    /// sends: an unknown enum name, an out-of-range index.
    InvalidValue,
    /// The allocator ran out of room duplicating a list field.
    OutOfMemory,
};

/// Reads fields out of one JSON object, treating an absent key and an explicit
/// JSON null alike (the framework uses null for every optional field, so the
/// two mean the same thing at the call sites). A present field of the wrong
/// type is `error.InvalidValue`.
const Fields = struct {
    object: std.json.ObjectMap,

    /// The raw value, or null when the key is absent or null.
    fn get(self: Fields, key: []const u8) ?std.json.Value {
        const value = self.object.get(key) orelse return null;
        return switch (value) {
            .null => null,
            else => value,
        };
    }

    /// A nullable string.
    fn string(self: Fields, key: []const u8) Error!?[]const u8 {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .string => |text| text,
            else => error.InvalidValue,
        };
    }

    /// A string the framework always sends.
    fn requiredString(self: Fields, key: []const u8) Error![]const u8 {
        return (try self.string(key)) orelse error.InvalidValue;
    }

    fn int(self: Fields, key: []const u8) Error!?i64 {
        const value = self.get(key) orelse return null;
        return try intFromJson(value);
    }

    fn intOr(self: Fields, key: []const u8, default: i64) Error!i64 {
        return (try self.int(key)) orelse default;
    }

    /// A nullable number, accepting a JSON integer where the framework declares
    /// a double (`fontSize: 14` is as valid as `14.0`).
    fn float(self: Fields, key: []const u8) Error!?f64 {
        const value = self.get(key) orelse return null;
        return try numberFromJson(value);
    }

    /// Named `flag` rather than `bool` to leave the primitive alone.
    fn flag(self: Fields, key: []const u8) Error!?bool {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .bool => |boolean| boolean,
            else => error.InvalidValue,
        };
    }

    fn flagOr(self: Fields, key: []const u8, default: bool) Error!bool {
        return (try self.flag(key)) orelse default;
    }

    /// The items of a JSON array.
    fn array(self: Fields, key: []const u8) Error!?[]std.json.Value {
        const value = self.get(key) orelse return null;
        return switch (value) {
            .array => |list| list.items,
            else => error.InvalidValue,
        };
    }
};

fn fieldsOf(value: std.json.Value) Error!Fields {
    return switch (value) {
        .object => |object| .{ .object = object },
        else => error.InvalidJson,
    };
}

/// An integer. A stringified number is accepted too, for callers that decode
/// with `parse_numbers = false`, but a genuine JSON float is not: the framework
/// casts these with `as int`, so a float would be a protocol error there too.
fn intFromJson(value: std.json.Value) Error!i64 {
    return switch (value) {
        .integer => |int| int,
        .number_string, .string => |text| std.fmt.parseInt(i64, text, 10) catch error.InvalidValue,
        else => error.InvalidJson,
    };
}

/// A number from any of the parser's number forms.
fn numberFromJson(value: std.json.Value) Error!f64 {
    return switch (value) {
        .integer => |int| @floatFromInt(int),
        .float => |float| float,
        .number_string, .string => |text| std.fmt.parseFloat(f64, text) catch error.InvalidValue,
        else => error.InvalidJson,
    };
}

/// An enum sent as `toString()`, i.e. `"Type.member"`. The bare member name is
/// accepted as well, since some embedders drop the prefix.
fn enumFromWireName(comptime E: type, comptime prefix: []const u8, value: std.json.Value) Error!E {
    const raw = switch (value) {
        .string => |text| text,
        else => return error.InvalidJson,
    };
    const name = if (std.mem.startsWith(u8, raw, prefix ++ ".")) raw[prefix.len + 1 ..] else raw;
    return std.meta.stringToEnum(E, name) orelse error.InvalidValue;
}

/// An enum sent as its index, either as a number or as a stringified one.
fn enumFromIndex(comptime E: type, value: std.json.Value) Error!E {
    const index = switch (value) {
        .integer => |int| int,
        .number_string, .string => |text| std.fmt.parseInt(i64, text, 10) catch return error.InvalidValue,
        else => return error.InvalidJson,
    };
    // `fromInt` looks the index up in the enum rather than casting it, so an
    // out-of-range index is an error here instead of a panic.
    return std.enums.fromInt(E, index) orelse error.InvalidValue;
}

/// Duplicate a JSON array of strings, since `[]const []const u8` cannot point
/// into the parser's array of values. The strings themselves stay borrowed; the
/// caller owns the slice and frees it in `deinit`.
fn stringList(allocator: std.mem.Allocator, values: ?[]std.json.Value) Error![]const []const u8 {
    const items = values orelse return &.{};

    const list = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(list);
    for (items, 0..) |item, i| {
        list[i] = switch (item) {
            .string => |text| text,
            else => return error.InvalidValue,
        };
    }
    return list;
}

// ---------------------------------------------------------------------------
// Text positions and ranges (`dart:ui` ui/text.dart, services/text_editing.dart)
// ---------------------------------------------------------------------------

/// Which side of an offset a caret affiliates with. The index is the wire form
/// (`selectionAffinity`, sent as `toString()`).
pub const TextAffinity = enum(u8) {
    upstream = 0,
    downstream = 1,

    pub fn fromJson(value: std.json.Value) Error!TextAffinity {
        return enumFromWireName(TextAffinity, "TextAffinity", value);
    }
};

/// A position in a string.
pub const TextPosition = struct {
    offset: i64,
    affinity: TextAffinity = .downstream,

    /// Not sent as its own object by the framework, which only ever decodes a
    /// position out of a `TextSelection` or a starting location; this reads the
    /// natural `{"offset", "affinity"}` form.
    pub fn fromJson(value: std.json.Value) Error!TextPosition {
        const fields = try fieldsOf(value);
        return .{
            .offset = try fields.intOr("offset", 0),
            .affinity = if (fields.get("affinity")) |affinity| try TextAffinity.fromJson(affinity) else .downstream,
        };
    }
};

/// A range of characters in a string.
///
/// `start` and `end` are both `-1` for the canonical "empty, outside the text"
/// range; see `empty`.
pub const TextRange = struct {
    start: i64,
    end: i64,

    /// A range that is empty and not inside the text.
    pub const empty: TextRange = .{ .start = -1, .end = -1 };

    pub fn collapsed(offset: i64) TextRange {
        return .{ .start = offset, .end = offset };
    }

    /// Whether the range is inside the text.
    pub fn isValid(self: TextRange) bool {
        return self.start >= 0 and self.end >= 0;
    }

    pub fn isCollapsed(self: TextRange) bool {
        return self.start == self.end;
    }

    /// Whether the start precedes the end. Callers that slice text with a range
    /// must check this first.
    pub fn isNormalized(self: TextRange) bool {
        return self.end >= self.start;
    }

    /// The `{"start", "end"}` form. The framework never sends a range as its
    /// own object: the composing region arrives flattened inside
    /// `TextEditingValue`, which builds this directly.
    pub fn fromJson(value: std.json.Value) Error!TextRange {
        const fields = try fieldsOf(value);
        return .{
            .start = try fields.intOr("start", -1),
            .end = try fields.intOr("end", -1),
        };
    }
};

/// A selection: a range plus the direction it was dragged in.
///
/// `baseOffset` is where the selection was started and may be greater than
/// `extentOffset`; `start`/`end` are derived, as in Dart.
pub const TextSelection = struct {
    baseOffset: i64,
    extentOffset: i64,
    affinity: TextAffinity = .downstream,
    /// Whether base/extent have been disambiguated by a user selection.
    isDirectional: bool = false,

    /// `TextSelection.collapsed(offset: -1)`: no caret, no selection. This is
    /// `TextEditingValue`'s default selection.
    pub const invalid: TextSelection = .{ .baseOffset = -1, .extentOffset = -1 };

    pub fn collapsed(offset: i64) TextSelection {
        return .{ .baseOffset = offset, .extentOffset = offset };
    }

    /// The first offset in the selection.
    pub fn start(self: TextSelection) i64 {
        return @min(self.baseOffset, self.extentOffset);
    }

    /// The offset just past the selection.
    pub fn end(self: TextSelection) i64 {
        return @max(self.baseOffset, self.extentOffset);
    }

    pub fn isValid(self: TextSelection) bool {
        return self.baseOffset >= 0 and self.extentOffset >= 0;
    }

    pub fn isCollapsed(self: TextSelection) bool {
        return self.baseOffset == self.extentOffset;
    }

    /// The `{"baseOffset", "extentOffset", "affinity", "isDirectional"}` form,
    /// i.e. the Dart field names. The framework flattens these into
    /// `TextEditingValue` (`selectionBase`, `selectionExtent`, ...) instead, so
    /// this is only for a nested selection; that flat form is decoded by
    /// `TextEditingValue.fromJson`.
    pub fn fromJson(value: std.json.Value) Error!TextSelection {
        const fields = try fieldsOf(value);
        return .{
            .baseOffset = try fields.intOr("baseOffset", -1),
            .extentOffset = try fields.intOr("extentOffset", -1),
            .affinity = if (fields.get("affinity")) |affinity| try TextAffinity.fromJson(affinity) else .downstream,
            .isDirectional = try fields.flagOr("isDirectional", false),
        };
    }
};

/// The text, selection and composing state of an editing session. Sent in both
/// directions: `TextInput.setEditingState` (framework to embedder) and
/// `TextInputClient.updateEditingState` (embedder to framework).
pub const TextEditingValue = struct {
    text: []const u8 = "",
    selection: TextSelection = TextSelection.invalid,
    /// The region the IME is still composing; `TextRange.empty` when nothing is
    /// being composed.
    composing: TextRange = TextRange.empty,

    /// An empty value with no caret and no composing region.
    pub const empty: TextEditingValue = .{};

    /// The framework's flattened form, mirroring `TextEditingValue.fromJSON`:
    /// `text` plus `selectionBase`/`selectionExtent`/`selectionAffinity`/
    /// `selectionIsDirectional` and `composingBase`/`composingExtent`. A `-1`
    /// in either pair means "no selection" or "no composing region", which is
    /// also the default when the pair is missing.
    pub fn fromJson(value: std.json.Value) Error!TextEditingValue {
        const fields = try fieldsOf(value);
        return .{
            .text = try fields.requiredString("text"),
            .selection = .{
                .baseOffset = try fields.intOr("selectionBase", -1),
                .extentOffset = try fields.intOr("selectionExtent", -1),
                .affinity = if (fields.get("selectionAffinity")) |affinity| try TextAffinity.fromJson(affinity) else .downstream,
                .isDirectional = try fields.flagOr("selectionIsDirectional", false),
            },
            .composing = .{
                .start = try fields.intOr("composingBase", -1),
                .end = try fields.intOr("composingExtent", -1),
            },
        };
    }
};

// ---------------------------------------------------------------------------
// Geometry and painting (`dart:ui`)
//
// These reach the channel as flattened numbers or indices, so they are modelled
// here only as far as the text input types need them.
// ---------------------------------------------------------------------------

/// An offset in logical pixels.
pub const Offset = struct {
    dx: f64,
    dy: f64,

    /// The framework's only offset on the wire is the floating cursor's point
    /// map, whose keys are capitalised (`{"X": .., "Y": ..}`). The lowercase
    /// spelling is accepted too, since embedders have sent both.
    pub fn fromJson(value: std.json.Value) Error!Offset {
        const fields = try fieldsOf(value);
        return .{
            .dx = (try fields.float("X")) orelse (try fields.float("x")) orelse 0,
            .dy = (try fields.float("Y")) orelse (try fields.float("y")) orelse 0,
        };
    }
};

/// A 2D size in logical pixels.
pub const Size = struct {
    width: f64,
    height: f64,

    /// Not sent as an object by the framework: a placeholder's size arrives as
    /// two positional numbers, alongside its offset. This reads the natural
    /// `{"width", "height"}` form.
    pub fn fromJson(value: std.json.Value) Error!Size {
        const fields = try fieldsOf(value);
        return .{
            .width = (try fields.float("width")) orelse 0,
            .height = (try fields.float("height")) orelse 0,
        };
    }
};

/// An axis-aligned rectangle.
pub const Rect = struct {
    left: f64,
    top: f64,
    right: f64,
    bottom: f64,

    pub fn width(self: Rect) f64 {
        return self.right - self.left;
    }

    pub fn height(self: Rect) f64 {
        return self.bottom - self.top;
    }

    /// The form the framework uses for `TextInput.setCaretRect` and friends:
    /// a corner plus a size, `{"x", "y", "width", "height"}`.
    pub fn fromJson(value: std.json.Value) Error!Rect {
        const fields = try fieldsOf(value);
        const x = (try fields.float("x")) orelse 0;
        const y = (try fields.float("y")) orelse 0;
        return .{
            .left = x,
            .top = y,
            .right = x + ((try fields.float("width")) orelse 0),
            .bottom = y + ((try fields.float("height")) orelse 0),
        };
    }
};

/// Text flow direction. The index is the wire form.
pub const TextDirection = enum(u8) {
    rtl = 0,
    ltr = 1,

    pub fn fromJson(value: std.json.Value) Error!TextDirection {
        return enumFromIndex(TextDirection, value);
    }
};

/// A typeface thickness. Dart models this as a class with a CSS `value`
/// (100..900) and an `index` (0..8); the channel sends the index.
pub const FontWeight = enum(u8) {
    w100 = 0,
    w200 = 1,
    w300 = 2,
    w400 = 3,
    w500 = 4,
    w600 = 5,
    w700 = 6,
    w800 = 7,
    w900 = 8,

    pub fn fromJson(value: std.json.Value) Error!FontWeight {
        return enumFromIndex(FontWeight, value);
    }
};

/// Horizontal text alignment. The index is the wire form.
pub const TextAlign = enum(u8) {
    left = 0,
    right = 1,
    center = 2,
    justify = 3,
    start = 4,
    end = 5,

    pub fn fromJson(value: std.json.Value) Error!TextAlign {
        return enumFromIndex(TextAlign, value);
    }
};

/// Light or dark, used for `keyboardAppearance`. Unlike the other enums this is
/// sent as `toString()` (`Brightness.light`), not as an index.
pub const Brightness = enum(u8) {
    dark = 0,
    light = 1,

    pub fn fromJson(value: std.json.Value) Error!Brightness {
        return enumFromWireName(Brightness, "Brightness", value);
    }
};

/// A rectangle enclosing a run of selected text, sent by
/// `TextInput.setSelectionRects`. On the wire each rect is flattened to
/// `[left, top, width, height, position, direction.index]`.
pub const SelectionRect = struct {
    position: i64,
    bounds: Rect,
    direction: TextDirection = .ltr,

    pub fn fromJson(value: std.json.Value) Error!SelectionRect {
        const items = switch (value) {
            .array => |list| list.items,
            else => return error.InvalidJson,
        };
        if (items.len < 6) return error.InvalidValue;

        const left = try numberFromJson(items[0]);
        const top = try numberFromJson(items[1]);
        return .{
            .position = try intFromJson(items[4]),
            .direction = try TextDirection.fromJson(items[5]),
            .bounds = .{
                .left = left,
                .top = top,
                .right = left + try numberFromJson(items[2]),
                .bottom = top + try numberFromJson(items[3]),
            },
        };
    }
};

/// Styling for the text being edited, sent by `TextInput.setStyle`. Only the
/// two required fields are always meaningful to an embedder; the rest are
/// hints for iOS/Android keyboards.
pub const TextInputStyle = struct {
    textDirection: TextDirection,
    textAlign: TextAlign,
    fontFamily: ?[]const u8 = null,
    fontSize: ?f64 = null,
    fontWeight: ?FontWeight = null,
    letterSpacing: ?f64 = null,
    wordSpacing: ?f64 = null,
    lineHeight: ?f64 = null,

    /// The style's JSON renames every enum field with an `Index` suffix, so
    /// this is not simply the field list.
    pub fn fromJson(value: std.json.Value) Error!TextInputStyle {
        const fields = try fieldsOf(value);
        return .{
            .textDirection = if (fields.get("textDirectionIndex")) |index|
                try TextDirection.fromJson(index)
            else
                .ltr,
            .textAlign = if (fields.get("textAlignIndex")) |index|
                try TextAlign.fromJson(index)
            else
                .left,
            .fontFamily = try fields.string("fontFamily"),
            .fontSize = try fields.float("fontSize"),
            .fontWeight = if (fields.get("fontWeightIndex")) |index|
                try FontWeight.fromJson(index)
            else
                null,
            .letterSpacing = try fields.float("letterSpacing"),
            .wordSpacing = try fields.float("wordSpacing"),
            .lineHeight = try fields.float("lineHeight"),
        };
    }
};

// ---------------------------------------------------------------------------
// Configuration (`services/text_input.dart`)
// ---------------------------------------------------------------------------

/// Whether the platform may autocorrect dashes. Sent as the index in a string
/// (`"0"`/`"1"`).
pub const SmartDashesType = enum(u8) {
    disabled = 0,
    enabled = 1,

    pub fn fromJson(value: std.json.Value) Error!SmartDashesType {
        return enumFromIndex(SmartDashesType, value);
    }
};

/// Whether the platform may autocorrect quotes. Sent as the index in a string.
pub const SmartQuotesType = enum(u8) {
    disabled = 0,
    enabled = 1,

    pub fn fromJson(value: std.json.Value) Error!SmartQuotesType {
        return enumFromIndex(SmartQuotesType, value);
    }
};

/// How the platform capitalises typed text. Sent as `toString()`.
pub const TextCapitalization = enum(u8) {
    words = 0,
    sentences = 1,
    characters = 2,
    none = 3,

    pub fn fromJson(value: std.json.Value) Error!TextCapitalization {
        return enumFromWireName(TextCapitalization, "TextCapitalization", value);
    }
};

/// The kind of input the framework wants.
///
/// Dart models this as a class rather than an enum: an index plus the `signed`
/// and `decimal` flags that only the numeric types use. Sent as
/// `{"name": "TextInputType.number", "signed": bool?, "decimal": bool?}`.
pub const TextInputType = struct {
    index: Index,
    signed: ?bool = null,
    decimal: ?bool = null,

    /// Indices are fixed by the framework.
    pub const Index = enum(u8) {
        text = 0,
        multiline = 1,
        number = 2,
        phone = 3,
        datetime = 4,
        emailAddress = 5,
        url = 6,
        visiblePassword = 7,
        name = 8,
        streetAddress = 9,
        none = 10,
        webSearch = 11,
        twitter = 12,
    };

    /// The wire spelling of each index. Note that this is not always the tag
    /// name: index 9 is sent as `address`, not `streetAddress`.
    pub const names = [_][]const u8{
        "text",
        "multiline",
        "number",
        "phone",
        "datetime",
        "emailAddress",
        "url",
        "visiblePassword",
        "name",
        "address",
        "none",
        "webSearch",
        "twitter",
    };

    pub const text: TextInputType = .{ .index = .text };
    pub const multiline: TextInputType = .{ .index = .multiline };
    pub const number: TextInputType = .{ .index = .number };
    pub const phone: TextInputType = .{ .index = .phone };
    pub const datetime: TextInputType = .{ .index = .datetime };
    pub const emailAddress: TextInputType = .{ .index = .emailAddress };
    pub const url: TextInputType = .{ .index = .url };
    pub const visiblePassword: TextInputType = .{ .index = .visiblePassword };
    pub const name: TextInputType = .{ .index = .name };
    pub const streetAddress: TextInputType = .{ .index = .streetAddress };
    pub const none: TextInputType = .{ .index = .none };
    pub const webSearch: TextInputType = .{ .index = .webSearch };
    pub const twitter: TextInputType = .{ .index = .twitter };

    /// The numeric keyboard, with or without a sign and a decimal separator
    /// (`TextInputType.numberWithOptions`).
    pub fn numberWithOptions(signed: bool, decimal: bool) TextInputType {
        return .{ .index = .number, .signed = signed, .decimal = decimal };
    }

    /// The `{"name", "signed", "decimal"}` object. The name is
    /// `TextInputType.<wire name>`, which is why `names` exists: the spelling
    /// is not always the tag (index 9 is `address`).
    pub fn fromJson(value: std.json.Value) Error!TextInputType {
        const fields = try fieldsOf(value);
        const spelling = try fields.requiredString("name");
        const wire = if (std.mem.startsWith(u8, spelling, "TextInputType."))
            spelling["TextInputType.".len..]
        else
            spelling;

        const index = for (names, 0..) |candidate, i| {
            if (std.mem.eql(u8, wire, candidate)) {
                break std.enums.fromInt(Index, i) orelse return error.InvalidValue;
            }
        } else return error.InvalidValue;

        return .{
            .index = index,
            .signed = try fields.flag("signed"),
            .decimal = try fields.flag("decimal"),
        };
    }
};

/// What the IME's action button should do. Sent as `toString()`.
///
/// Dart names the `continue` member `continueAction` because of the keyword,
/// and the wire name keeps that spelling (`TextInputAction.continueAction`).
pub const TextInputAction = enum(u8) {
    none = 0,
    unspecified = 1,
    done = 2,
    go = 3,
    search = 4,
    send = 5,
    next = 6,
    previous = 7,
    continueAction = 8,
    join = 9,
    route = 10,
    emergencyCall = 11,
    newline = 12,

    pub fn fromJson(value: std.json.Value) Error!TextInputAction {
        return enumFromWireName(TextInputAction, "TextInputAction", value);
    }
};

/// Autofill metadata for the focused field. Nested in
/// `TextInputConfiguration`; a disabled configuration is sent as JSON null
/// rather than as an object.
pub const AutofillConfiguration = struct {
    uniqueIdentifier: []const u8 = "",
    autofillHints: []const []const u8 = &.{},
    hintText: ?[]const u8 = null,
    enabled: bool = true,
    /// Sent as `editingValue`, so the platform can offer the current text as an
    /// autofill suggestion.
    currentEditingValue: TextEditingValue = .{},

    /// `AutofillConfiguration.disabled`, the default in
    /// `TextInputConfiguration`.
    pub const disabled: AutofillConfiguration = .{ .enabled = false };

    /// The `{"uniqueIdentifier", "hints", "editingValue", "hintText"}` object;
    /// the hints are the wire key for `autofillHints`. The framework omits
    /// `hintText` when it is null, and never sends `enabled` at all (a disabled
    /// configuration is JSON null, so the presence of the object is the flag);
    /// `enabled` is read only for tolerance.
    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) Error!AutofillConfiguration {
        const fields = try fieldsOf(value);

        // Everything fallible that does not allocate is resolved before the
        // hints, so that a later failure cannot leak them.
        const uniqueIdentifier = (try fields.string("uniqueIdentifier")) orelse "";
        const hintText = try fields.string("hintText");
        const enabled = try fields.flagOr("enabled", true);
        const currentEditingValue = if (fields.get("editingValue")) |editingValue|
            try TextEditingValue.fromJson(editingValue)
        else
            TextEditingValue.empty;

        return .{
            .uniqueIdentifier = uniqueIdentifier,
            .autofillHints = try stringList(allocator, try fields.array("hints")),
            .hintText = hintText,
            .enabled = enabled,
            .currentEditingValue = currentEditingValue,
        };
    }

    /// Free the duplicated hints. Only valid on a value from `fromJson`.
    pub fn deinit(self: *AutofillConfiguration, allocator: std.mem.Allocator) void {
        allocator.free(self.autofillHints);
    }
};

/// Sent by `TextInput.setClient` (as its second argument) and replaced by
/// `TextInput.updateConfig` whenever the framework's configuration changes.
pub const TextInputConfiguration = struct {
    /// The view the field belongs to; null means "the focused view".
    viewId: ?i64 = null,
    inputType: TextInputType = TextInputType.text,
    readOnly: bool = false,
    obscureText: bool = false,
    autocorrect: bool = true,
    /// Dart derives `smartDashesType`/`smartQuotesType` from `obscureText` when
    /// the caller omits them (disabled for password fields); here they are plain
    /// fields because the wire always carries a resolved value.
    smartDashesType: SmartDashesType = .enabled,
    smartQuotesType: SmartQuotesType = .enabled,
    enableSuggestions: bool = true,
    enableInteractiveSelection: bool = true,
    actionLabel: ?[]const u8 = null,
    inputAction: TextInputAction = .done,
    textCapitalization: TextCapitalization = .none,
    keyboardAppearance: Brightness = .light,
    autofillConfiguration: AutofillConfiguration = AutofillConfiguration.disabled,
    enableIMEPersonalizedLearning: bool = true,
    allowedMimeTypes: []const []const u8 = &.{},
    /// Opt in to `TextInputClient.updateEditingStateWithDeltas` (not ported).
    enableDeltaModel: bool = false,
    /// Language tags such as `"en-US"`.
    hintLocales: []const []const u8 = &.{},
    enableInlinePrediction: ?bool = null,

    /// The `setClient`/`updateConfig` object, i.e. the inverse of the
    /// framework's `TextInputConfiguration.toJson`. Two keys are renamed on the
    /// wire: `contentCommitMimeTypes` for `allowedMimeTypes`, and `autofill`
    /// for `autofillConfiguration` (sent as null, rather than as an object,
    /// when autofill is disabled).
    pub fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) Error!TextInputConfiguration {
        const fields = try fieldsOf(value);

        // Decode everything that cannot allocate first, then the three list
        // fields, so that a failure anywhere frees what was already allocated.
        const viewId = try fields.int("viewId");
        const readOnly = try fields.flagOr("readOnly", false);
        const obscureText = try fields.flagOr("obscureText", false);
        const autocorrect = try fields.flagOr("autocorrect", true);
        const enableSuggestions = try fields.flagOr("enableSuggestions", true);
        const enableInteractiveSelection = try fields.flagOr("enableInteractiveSelection", true);
        const enableIMEPersonalizedLearning = try fields.flagOr("enableIMEPersonalizedLearning", true);
        const enableDeltaModel = try fields.flagOr("enableDeltaModel", false);
        const enableInlinePrediction = try fields.flag("enableInlinePrediction");
        const actionLabel = try fields.string("actionLabel");

        const inputType = if (fields.get("inputType")) |inputType|
            try TextInputType.fromJson(inputType)
        else
            TextInputType.text;
        const smartDashesType = if (fields.get("smartDashesType")) |smartDashesType|
            try SmartDashesType.fromJson(smartDashesType)
        else
            .enabled;
        const smartQuotesType = if (fields.get("smartQuotesType")) |smartQuotesType|
            try SmartQuotesType.fromJson(smartQuotesType)
        else
            .enabled;
        const inputAction = if (fields.get("inputAction")) |inputAction|
            try TextInputAction.fromJson(inputAction)
        else
            .done;
        const textCapitalization = if (fields.get("textCapitalization")) |textCapitalization|
            try TextCapitalization.fromJson(textCapitalization)
        else
            .none;
        const keyboardAppearance = if (fields.get("keyboardAppearance")) |keyboardAppearance|
            try Brightness.fromJson(keyboardAppearance)
        else
            .light;

        const autofillConfiguration = if (fields.get("autofill")) |autofill|
            try AutofillConfiguration.fromJson(allocator, autofill)
        else
            AutofillConfiguration.disabled;
        errdefer {
            var owned = autofillConfiguration;
            owned.deinit(allocator);
        }

        const allowedMimeTypes = try stringList(allocator, try fields.array("contentCommitMimeTypes"));
        errdefer allocator.free(allowedMimeTypes);
        const hintLocales = try stringList(allocator, try fields.array("hintLocales"));
        errdefer allocator.free(hintLocales);

        return .{
            .viewId = viewId,
            .inputType = inputType,
            .readOnly = readOnly,
            .obscureText = obscureText,
            .autocorrect = autocorrect,
            .smartDashesType = smartDashesType,
            .smartQuotesType = smartQuotesType,
            .enableSuggestions = enableSuggestions,
            .enableInteractiveSelection = enableInteractiveSelection,
            .actionLabel = actionLabel,
            .inputAction = inputAction,
            .textCapitalization = textCapitalization,
            .keyboardAppearance = keyboardAppearance,
            .autofillConfiguration = autofillConfiguration,
            .enableIMEPersonalizedLearning = enableIMEPersonalizedLearning,
            .allowedMimeTypes = allowedMimeTypes,
            .enableDeltaModel = enableDeltaModel,
            .hintLocales = hintLocales,
            .enableInlinePrediction = enableInlinePrediction,
        };
    }

    /// Free the duplicated list fields and the nested autofill configuration.
    /// Only valid on a value from `fromJson`.
    pub fn deinit(self: *TextInputConfiguration, allocator: std.mem.Allocator) void {
        allocator.free(self.allowedMimeTypes);
        allocator.free(self.hintLocales);
        self.autofillConfiguration.deinit(allocator);
    }
};

// ---------------------------------------------------------------------------
// Floating cursor (iOS)
// ---------------------------------------------------------------------------

/// The state of a floating cursor. Sent as `toString()`
/// (`FloatingCursorDragState.start`), capitalised tag and all.
pub const FloatingCursorDragState = enum(u8) {
    start = 0,
    update = 1,
    end = 2,

    pub fn fromJson(value: std.json.Value) Error!FloatingCursorDragState {
        return enumFromWireName(FloatingCursorDragState, "FloatingCursorDragState", value);
    }
};

/// A floating cursor position, sent by the embedder in
/// `TextInputClient.updateFloatingCursor`.
pub const RawFloatingCursorPoint = struct {
    state: FloatingCursorDragState,
    /// Present for every state but `start`.
    offset: ?Offset = null,
    /// Only present for `start`. Dart models this as the record
    /// `(Offset, TextPosition)`.
    startLocation: ?StartLocation = null,

    pub const StartLocation = struct {
        offset: Offset,
        position: TextPosition,
    };

    /// The two arguments the framework sends for this call are siblings in the
    /// argument list: the state string, and the point map. The latter always
    /// carries `X`/`Y`, but the framework reads them only while the state is
    /// `update` and uses `Offset.zero` otherwise, which is what the default of
    /// `Offset.fromJson` gives. `startLocation` is never sent, so it stays null.
    pub fn fromJson(value: std.json.Value, state: FloatingCursorDragState) Error!RawFloatingCursorPoint {
        return .{
            .state = state,
            .offset = try Offset.fromJson(value),
        };
    }
};

test "configuration defaults mirror the Dart constructor" {
    const testing = std.testing;
    const config = TextInputConfiguration{};

    try testing.expectEqual(@as(?i64, null), config.viewId);
    try testing.expectEqual(TextInputType.Index.text, config.inputType.index);
    try testing.expectEqual(@as(?bool, null), config.inputType.signed);
    try testing.expectEqual(@as(?bool, null), config.inputType.decimal);
    try testing.expect(!config.readOnly);
    try testing.expect(!config.obscureText);
    try testing.expect(config.autocorrect);
    try testing.expectEqual(SmartDashesType.enabled, config.smartDashesType);
    try testing.expectEqual(SmartQuotesType.enabled, config.smartQuotesType);
    try testing.expect(config.enableSuggestions);
    try testing.expect(config.enableInteractiveSelection);
    try testing.expectEqual(@as(?[]const u8, null), config.actionLabel);
    try testing.expectEqual(TextInputAction.done, config.inputAction);
    try testing.expectEqual(TextCapitalization.none, config.textCapitalization);
    try testing.expectEqual(Brightness.light, config.keyboardAppearance);
    try testing.expect(!config.autofillConfiguration.enabled);
    try testing.expect(config.enableIMEPersonalizedLearning);
    try testing.expectEqual(@as(usize, 0), config.allowedMimeTypes.len);
    try testing.expect(!config.enableDeltaModel);
    try testing.expectEqual(@as(usize, 0), config.hintLocales.len);
    try testing.expectEqual(@as(?bool, null), config.enableInlinePrediction);
}

test "text input type carries the wire name and the numeric flags" {
    const testing = std.testing;

    const numeric = TextInputType.numberWithOptions(true, false);
    try testing.expectEqual(TextInputType.Index.number, numeric.index);
    try testing.expectEqual(@as(?bool, true), numeric.signed);
    try testing.expectEqual(@as(?bool, false), numeric.decimal);
    try testing.expectEqualStrings("number", TextInputType.names[@backingInt(numeric.index)]);

    // The tag name and the wire name differ for the street address.
    try testing.expectEqualStrings("address", TextInputType.names[@backingInt(TextInputType.streetAddress.index)]);
}

test "selection and range helpers" {
    const testing = std.testing;

    const reversed = TextSelection{ .baseOffset = 5, .extentOffset = 2 };
    try testing.expectEqual(@as(i64, 2), reversed.start());
    try testing.expectEqual(@as(i64, 5), reversed.end());
    try testing.expect(reversed.isValid());
    try testing.expect(!reversed.isCollapsed());

    try testing.expect(!TextSelection.invalid.isValid());
    try testing.expect(TextSelection.invalid.isCollapsed());
    try testing.expectEqual(@as(i64, -1), TextSelection.invalid.start());

    try testing.expect(!TextRange.empty.isValid());
    try testing.expect(TextRange.empty.isNormalized());
    try testing.expect(TextRange.collapsed(3).isCollapsed());
}

/// Parse `text` into the `std.json.Value` tree that `fromJson` consumes.
fn parseJson(text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
}

test "setEditingState decodes the framework's flattened editing value" {
    const testing = std.testing;
    var parsed = try parseJson(
        \\{"text":"héllo","selectionBase":5,"selectionExtent":2,
        \\ "selectionAffinity":"TextAffinity.upstream","selectionIsDirectional":true,
        \\ "composingBase":0,"composingExtent":1}
    );
    defer parsed.deinit();

    const value = try TextEditingValue.fromJson(parsed.value);
    try testing.expectEqualStrings("héllo", value.text);
    try testing.expectEqual(@as(i64, 5), value.selection.baseOffset);
    try testing.expectEqual(@as(i64, 2), value.selection.extentOffset);
    try testing.expectEqual(@as(i64, 2), value.selection.start());
    try testing.expectEqual(@as(i64, 5), value.selection.end());
    try testing.expectEqual(TextAffinity.upstream, value.selection.affinity);
    try testing.expect(value.selection.isDirectional);
    try testing.expectEqual(@as(i64, 0), value.composing.start);
    try testing.expectEqual(@as(i64, 1), value.composing.end);

    // Only the text is mandatory; the rest of the message is optional and
    // defaults to "nothing selected, nothing composing".
    var minimal = try parseJson(
        \\{"text":""}
    );
    defer minimal.deinit();
    const empty = try TextEditingValue.fromJson(minimal.value);
    try testing.expectEqualStrings("", empty.text);
    try testing.expectEqual(TextSelection.invalid, empty.selection);
    try testing.expectEqual(TextRange.empty, empty.composing);
}

test "setClient decodes a whole text input configuration" {
    const testing = std.testing;
    var parsed = try parseJson(
        \\{"viewId":3,"inputType":{"name":"TextInputType.multiline"},
        \\ "readOnly":true,"obscureText":false,"autocorrect":false,
        \\ "smartDashesType":"0","smartQuotesType":"1","enableSuggestions":false,
        \\ "enableInteractiveSelection":true,"actionLabel":"Send",
        \\ "inputAction":"TextInputAction.send",
        \\ "textCapitalization":"TextCapitalization.words",
        \\ "keyboardAppearance":"Brightness.dark","enableIMEPersonalizedLearning":false,
        \\ "contentCommitMimeTypes":["text/plain;charset=utf-8"],
        \\ "autofill":{"uniqueIdentifier":"id-1","hints":["email","name"],"hintText":"Email",
        \\ "editingValue":{"text":"a@b","selectionBase":3,"selectionExtent":3}},
        \\ "enableDeltaModel":true,"hintLocales":["en-US","fr"],"enableInlinePrediction":true}
    );
    defer parsed.deinit();

    var config = try TextInputConfiguration.fromJson(testing.allocator, parsed.value);
    defer config.deinit(testing.allocator);

    try testing.expectEqual(@as(?i64, 3), config.viewId);
    try testing.expectEqual(TextInputType.Index.multiline, config.inputType.index);
    try testing.expectEqual(@as(?bool, null), config.inputType.signed);
    try testing.expect(config.readOnly);
    try testing.expect(!config.obscureText);
    try testing.expect(!config.autocorrect);
    try testing.expectEqual(SmartDashesType.disabled, config.smartDashesType);
    try testing.expectEqual(SmartQuotesType.enabled, config.smartQuotesType);
    try testing.expect(!config.enableSuggestions);
    try testing.expect(config.enableInteractiveSelection);
    try testing.expectEqualStrings("Send", config.actionLabel.?);
    try testing.expectEqual(TextInputAction.send, config.inputAction);
    try testing.expectEqual(TextCapitalization.words, config.textCapitalization);
    try testing.expectEqual(Brightness.dark, config.keyboardAppearance);
    try testing.expect(!config.enableIMEPersonalizedLearning);
    try testing.expectEqual(@as(usize, 1), config.allowedMimeTypes.len);
    try testing.expectEqualStrings("text/plain;charset=utf-8", config.allowedMimeTypes[0]);
    try testing.expectEqual(@as(usize, 2), config.hintLocales.len);
    try testing.expectEqualStrings("en-US", config.hintLocales[0]);
    try testing.expectEqualStrings("fr", config.hintLocales[1]);
    try testing.expect(config.enableDeltaModel);
    try testing.expectEqual(@as(?bool, true), config.enableInlinePrediction);

    const autofill = config.autofillConfiguration;
    try testing.expect(autofill.enabled);
    try testing.expectEqualStrings("id-1", autofill.uniqueIdentifier);
    try testing.expectEqual(@as(usize, 2), autofill.autofillHints.len);
    try testing.expectEqualStrings("email", autofill.autofillHints[0]);
    try testing.expectEqualStrings("name", autofill.autofillHints[1]);
    try testing.expectEqualStrings("Email", autofill.hintText.?);
    try testing.expectEqualStrings("a@b", autofill.currentEditingValue.text);
    try testing.expect(autofill.currentEditingValue.selection.isCollapsed());
    try testing.expectEqual(@as(i64, 3), autofill.currentEditingValue.selection.baseOffset);

    // An absent `autofill`, and a null one, both mean the disabled default.
    var without = try parseJson(
        \\{"inputType":{"name":"TextInputType.text"},"autofill":null}
    );
    defer without.deinit();
    var plain = try TextInputConfiguration.fromJson(testing.allocator, without.value);
    defer plain.deinit(testing.allocator);
    try testing.expect(!plain.autofillConfiguration.enabled);
    try testing.expectEqual(@as(usize, 0), plain.allowedMimeTypes.len);
    try testing.expectEqual(@as(usize, 0), plain.hintLocales.len);
}

test "wire spellings of the enums" {
    const testing = std.testing;

    try testing.expectEqual(TextAffinity.upstream, try TextAffinity.fromJson(.{ .string = "TextAffinity.upstream" }));
    try testing.expectEqual(TextAffinity.downstream, try TextAffinity.fromJson(.{ .string = "TextAffinity.downstream" }));
    // Some embedders drop the `Type.` prefix.
    try testing.expectEqual(TextAffinity.downstream, try TextAffinity.fromJson(.{ .string = "downstream" }));

    try testing.expectEqual(TextInputAction.continueAction, try TextInputAction.fromJson(.{ .string = "TextInputAction.continueAction" }));
    try testing.expectEqual(TextInputAction.newline, try TextInputAction.fromJson(.{ .string = "TextInputAction.newline" }));
    try testing.expectEqual(TextCapitalization.sentences, try TextCapitalization.fromJson(.{ .string = "TextCapitalization.sentences" }));
    try testing.expectEqual(Brightness.dark, try Brightness.fromJson(.{ .string = "Brightness.dark" }));
    try testing.expectEqual(FloatingCursorDragState.update, try FloatingCursorDragState.fromJson(.{ .string = "FloatingCursorDragState.update" }));

    // These four are indices, the two smart types as stringified indices.
    try testing.expectEqual(TextDirection.rtl, try TextDirection.fromJson(.{ .integer = 0 }));
    try testing.expectEqual(TextAlign.center, try TextAlign.fromJson(.{ .integer = 2 }));
    try testing.expectEqual(FontWeight.w700, try FontWeight.fromJson(.{ .integer = 6 }));
    try testing.expectEqual(SmartDashesType.enabled, try SmartDashesType.fromJson(.{ .string = "1" }));
    try testing.expectEqual(SmartDashesType.disabled, try SmartDashesType.fromJson(.{ .integer = 0 }));

    var numeric = try parseJson(
        \\{"name":"TextInputType.number","signed":true,"decimal":false}
    );
    defer numeric.deinit();
    const number = try TextInputType.fromJson(numeric.value);
    try testing.expectEqual(TextInputType.Index.number, number.index);
    try testing.expectEqual(@as(?bool, true), number.signed);
    try testing.expectEqual(@as(?bool, false), number.decimal);

    // The street address is the one index whose wire name is not its tag.
    var address = try parseJson(
        \\{"name":"TextInputType.address"}
    );
    defer address.deinit();
    try testing.expectEqual(TextInputType.streetAddress, try TextInputType.fromJson(address.value));

    // A floating cursor point: the two arguments of `updateFloatingCursor`.
    var point = try parseJson(
        \\{"X":12.5,"Y":-4}
    );
    defer point.deinit();
    const drag = try RawFloatingCursorPoint.fromJson(point.value, .update);
    try testing.expectEqual(FloatingCursorDragState.update, drag.state);
    try testing.expectEqual(@as(f64, 12.5), drag.offset.?.dx);
    try testing.expectEqual(@as(f64, -4), drag.offset.?.dy);
    try testing.expectEqual(@as(?RawFloatingCursorPoint.StartLocation, null), drag.startLocation);
}

test "flattened geometry decodes back into the dart:ui shapes" {
    const testing = std.testing;

    var rects = try parseJson(
        \\[[10,20,30,40,7,1]]
    );
    defer rects.deinit();
    const first = try SelectionRect.fromJson(rects.value.array.items[0]);
    try testing.expectEqual(@as(i64, 7), first.position);
    try testing.expectEqual(TextDirection.ltr, first.direction);
    try testing.expectEqual(@as(f64, 10), first.bounds.left);
    try testing.expectEqual(@as(f64, 20), first.bounds.top);
    try testing.expectEqual(@as(f64, 30), first.bounds.width());
    try testing.expectEqual(@as(f64, 40), first.bounds.height());

    // `setCaretRect` and `setMarkedTextRect` send a corner plus a size.
    var caret = try parseJson(
        \\{"x":5,"y":6,"width":30,"height":40}
    );
    defer caret.deinit();
    const bounds = try Rect.fromJson(caret.value);
    try testing.expectEqual(@as(f64, 5), bounds.left);
    try testing.expectEqual(@as(f64, 6), bounds.top);
    try testing.expectEqual(@as(f64, 35), bounds.right);
    try testing.expectEqual(@as(f64, 46), bounds.bottom);

    // `setStyle` renames every enum field with an `Index` suffix, and the
    // numbers may arrive as integers.
    var style = try parseJson(
        \\{"fontFamily":"Roboto","fontSize":14,"fontWeightIndex":6,"textAlignIndex":2,
        \\ "textDirectionIndex":0,"letterSpacing":1.5,"wordSpacing":null,"lineHeight":20}
    );
    defer style.deinit();
    const decoded = try TextInputStyle.fromJson(style.value);
    try testing.expectEqualStrings("Roboto", decoded.fontFamily.?);
    try testing.expectEqual(@as(f64, 14), decoded.fontSize.?);
    try testing.expectEqual(FontWeight.w700, decoded.fontWeight.?);
    try testing.expectEqual(TextAlign.center, decoded.textAlign);
    try testing.expectEqual(TextDirection.rtl, decoded.textDirection);
    try testing.expectEqual(@as(f64, 1.5), decoded.letterSpacing.?);
    try testing.expectEqual(@as(?f64, null), decoded.wordSpacing);
    try testing.expectEqual(@as(f64, 20), decoded.lineHeight.?);
}

test "fromJson rejects what the framework never sends" {
    const testing = std.testing;

    // A value of the wrong kind is a JSON error rather than a value one.
    try testing.expectError(error.InvalidJson, TextEditingValue.fromJson(.{ .string = "nope" }));
    try testing.expectError(error.InvalidJson, TextInputConfiguration.fromJson(testing.allocator, .{ .integer = 1 }));
    try testing.expectError(error.InvalidJson, TextInputStyle.fromJson(.{ .bool = true }));
    // ...and a flattened rect that is too short for its six numbers.
    try testing.expectError(error.InvalidValue, SelectionRect.fromJson(.{ .array = std.json.Array.init(testing.allocator) }));

    // A missing or wrongly typed field is an error, not a default.
    var noText = try parseJson(
        \\{"selectionBase":0}
    );
    defer noText.deinit();
    try testing.expectError(error.InvalidValue, TextEditingValue.fromJson(noText.value));

    var badText = try parseJson(
        \\{"text":7}
    );
    defer badText.deinit();
    try testing.expectError(error.InvalidValue, TextEditingValue.fromJson(badText.value));

    var badBool = try parseJson(
        \\{"name":"TextInputType.text","signed":"yes"}
    );
    defer badBool.deinit();
    try testing.expectError(error.InvalidValue, TextInputType.fromJson(badBool.value));

    // An unknown name or an out-of-range index is not a fallback either.
    try testing.expectError(error.InvalidValue, TextInputAction.fromJson(.{ .string = "TextInputAction.bogus" }));
    try testing.expectError(error.InvalidValue, TextDirection.fromJson(.{ .integer = 9 }));
    try testing.expectError(error.InvalidValue, SmartDashesType.fromJson(.{ .integer = 5 }));
    try testing.expectError(error.InvalidValue, TextAffinity.fromJson(.{ .string = "TextAffinity.sideways" }));

    var bogusType = try parseJson(
        \\{"name":"TextInputType.bogus"}
    );
    defer bogusType.deinit();
    try testing.expectError(error.InvalidValue, TextInputType.fromJson(bogusType.value));

    // A list field with a non-string entry fails the whole message.
    var badHints = try parseJson(
        \\{"inputType":{"name":"TextInputType.text"},"contentCommitMimeTypes":["text/plain",7]}
    );
    defer badHints.deinit();
    try testing.expectError(error.InvalidValue, TextInputConfiguration.fromJson(testing.allocator, badHints.value));
}
