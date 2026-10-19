const std = @import("std");

const c = @import("flutter");
const xkb = @import("xkb");
const engine = @import("../engine.zig");
const channels = @import("channels.zig");
const codec = @import("codec.zig");
const types = @import("types/text_input.zig");

const KEY_RETURN: u32 = @intCast(xkb.XKB_KEY_Return);
const KEY_KP_ENTER: u32 = @intCast(xkb.XKB_KEY_KP_Enter);
const KEY_ISO_ENTER: u32 = @intCast(xkb.XKB_KEY_ISO_Enter);

/// Implements the `flutter/textinput` platform channel, speaking the
/// `JSONMethodCodec` protocol the framework expects (see `TextInput` in the
/// framework's services/text_input.dart).
///
/// What the framework sends is decoded into the mirrored value types in
/// `types/text_input.zig`; what we send back is still written out by hand,
/// because those types have no `toJson` yet.
///
/// Editing keys (backspace/delete/arrows/home/end) are intentionally *not*
/// handled here: the framework's `DefaultTextEditingShortcuts` handles them
/// from the key events we send. The framework explicitly delegates space and
/// enter to the text input (`_commonShortcuts` in
/// default_text_editing_shortcuts.dart), and never inserts printable
/// characters itself, so those are the only edits we perform.
///
/// Offsets in the mirrored types are the framework's, i.e. UTF-16 code units,
/// while the buffer here is UTF-8, so the two agree only for BMP/ASCII text
/// until the offsets are converted. See `clampOffset`.
pub const TextInput = struct {
    allocator: std.mem.Allocator,
    eng: *engine.Engine,
    has_client: bool = false,
    client_id: i64 = 0,
    /// The pieces of `TextInputConfiguration` this embedder acts on. The rest
    /// is dropped, and none of the config's strings are kept: `fromJson` leaves
    /// those borrowed from the message, which is freed as soon as it has been
    /// handled.
    input_type: types.TextInputType = types.TextInputType.text,
    read_only: bool = false,
    input_action: types.TextInputAction = .done,
    /// The text being edited. `TextEditingValue` only borrows its text, so the
    /// buffer is owned here and `editingValue` hands out a view of it.
    text: std.ArrayListUnmanaged(u8) = .empty,
    selection: types.TextSelection = types.TextSelection.invalid,

    pub fn init(allocator: std.mem.Allocator, eng: *engine.Engine) TextInput {
        return .{ .allocator = allocator, .eng = eng };
    }

    pub fn deinit(self: *TextInput) void {
        self.text.deinit(self.allocator);
    }

    /// The editing state as the framework models it, borrowing the buffer.
    fn editingValue(self: *const TextInput) types.TextEditingValue {
        return .{ .text = self.text.items, .selection = self.selection };
    }

    /// Whether the field accepts newlines: the framework models a multiline
    /// field as the `multiline` input type.
    fn multiline(self: *const TextInput) bool {
        return self.input_type.index == .multiline;
    }

    /// Entry point for messages on the `flutter/textinput` channel.
    pub fn handlePlatformMessage(self: *TextInput, message: *const c.FlutterPlatformMessage) void {
        const msg = message.*;
        var data: []const u8 = &.{};
        if (msg.message != null) data = msg.message[0..msg.message_size];
        self.handleTextInput(data, msg.response_handle);
    }

    fn handleTextInput(self: *TextInput, data: []const u8, handle: ?*const c.FlutterPlatformMessageResponseHandle) void {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, data, .{}) catch {
            self.respondError(handle, "invalid json");
            return;
        };
        defer parsed.deinit();

        if (parsed.value != .object) {
            self.respondError(handle, "invalid message");
            return;
        }
        const message = parsed.value.object;
        const method_value = message.get("method") orelse {
            self.respondError(handle, "missing method");
            return;
        };
        if (method_value != .string) {
            self.respondError(handle, "invalid method");
            return;
        }
        const method = method_value.string;
        const args = message.get("args") orelse codec.no_args;

        // Every method's arguments are decoded here, so that the handlers below
        // only ever see the mirrored types.
        if (std.mem.eql(u8, method, "TextInput.setClient")) {
            var request = SetClientArgs.decode(self.allocator, args) catch {
                self.respondError(handle, "invalid setClient");
                return;
            };
            defer request.deinit(self.allocator);
            self.setClient(request.client_id, request.config);
        } else if (std.mem.eql(u8, method, "TextInput.clearClient")) {
            self.clearClient();
        } else if (std.mem.eql(u8, method, "TextInput.setEditingState")) {
            const state = types.TextEditingValue.fromJson(args) catch {
                self.respondError(handle, "invalid editing state");
                return;
            };
            self.setEditingState(state);
        } else if (std.mem.eql(u8, method, "TextInput.updateConfig")) {
            var config = types.TextInputConfiguration.fromJson(self.allocator, args) catch {
                self.respondError(handle, "invalid config");
                return;
            };
            defer config.deinit(self.allocator);
            self.applyConfig(config);
        } else if (std.mem.eql(u8, method, "TextInput.show") or
            std.mem.eql(u8, method, "TextInput.hide") or
            std.mem.eql(u8, method, "TextInput.setEditableSizeAndTransform") or
            std.mem.eql(u8, method, "TextInput.setMarkedTextRect") or
            std.mem.eql(u8, method, "TextInput.setCaretRect") or
            std.mem.eql(u8, method, "TextInput.setSelectionRects") or
            std.mem.eql(u8, method, "TextInput.setStyle") or
            std.mem.eql(u8, method, "TextInput.requestAutofill") or
            std.mem.eql(u8, method, "TextInput.finishAutofillContext") or
            std.mem.eql(u8, method, "TextInput.setPlatformViewClient") or
            std.mem.eql(u8, method, "TextInput.startLiveTextInput"))
        {
            // Accepted no-ops.
        } else {
            self.respondUnimplemented(handle, method);
            return;
        }

        self.eng.sendPlatformMessageResponse(handle, codec.json_success);
    }

    /// Focus a client: remember its connection id and apply its configuration.
    /// The config is only borrowed for the call; see `applyConfig`.
    fn setClient(self: *TextInput, client_id: i64, config: types.TextInputConfiguration) void {
        self.client_id = client_id;
        self.has_client = true;
        self.applyConfig(config);
    }

    fn clearClient(self: *TextInput) void {
        self.has_client = false;
        self.client_id = 0;
        self.text.clearRetainingCapacity();
        self.selection = types.TextSelection.invalid;
    }

    /// Keep the pieces of the framework's configuration this embedder acts on.
    /// The rest is dropped, including the config's strings, which `fromJson`
    /// leaves borrowed from the message being handled.
    fn applyConfig(self: *TextInput, config: types.TextInputConfiguration) void {
        self.input_type = config.inputType;
        self.read_only = config.readOnly;
        self.input_action = config.inputAction;
    }

    /// Replace the editing state with the one the framework reports. The
    /// composing region is dropped: there is no IME here, and the state we
    /// report back says so too.
    fn setEditingState(self: *TextInput, value: types.TextEditingValue) void {
        self.text.clearRetainingCapacity();
        self.text.appendSlice(self.allocator, value.text) catch {};
        self.selection = value.selection;
    }

    /// Feed a key press to the active text input client.
    pub fn handleKey(self: *TextInput, keysym: u32, codepoint: u32, pressed: bool) void {
        if (!pressed or !self.has_client or self.read_only) return;

        if (keysym == KEY_RETURN or keysym == KEY_KP_ENTER or keysym == KEY_ISO_ENTER) {
            if (self.multiline()) self.insertBytes("\n");
            self.performAction();
            return;
        }

        if (codepoint >= 0x20 and codepoint != 0x7f) {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
            self.insertBytes(buf[0..n]);
        }
    }

    fn insertBytes(self: *TextInput, bytes: []const u8) void {
        const len = self.text.items.len;
        var base = clampOffset(self.selection.baseOffset, len);
        var extent = clampOffset(self.selection.extentOffset, len);
        if (base > extent) std.mem.swap(usize, &base, &extent);

        self.text.replaceRange(self.allocator, base, extent - base, bytes) catch return;
        // The caret ends up after the insertion, with no affinity and no
        // directionality, which is what `sendEditingState` reports.
        self.selection = types.TextSelection.collapsed(@intCast(base + bytes.len));
        self.sendEditingState();
    }

    fn performAction(self: *TextInput) void {
        const gpa = self.allocator;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);

        out.appendSlice(gpa, "{\"method\":\"TextInputClient.performAction\",\"args\":[") catch return;
        codec.appendNum(&out, gpa, self.client_id) catch return;
        // The action is sent as `toString()`, and the Dart member name for the
        // continue key is the spelling the framework parses back.
        out.appendSlice(gpa, ",\"TextInputAction.") catch return;
        out.appendSlice(gpa, @tagName(self.input_action)) catch return;
        out.appendSlice(gpa, "\"]}") catch return;

        self.eng.sendPlatformMessage(channels.text_input.name.ptr, out.items);
    }

    fn sendEditingState(self: *TextInput) void {
        const gpa = self.allocator;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(gpa);

        const state = self.editingValue();
        out.appendSlice(gpa, "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[") catch return;
        codec.appendNum(&out, gpa, self.client_id) catch return;
        out.appendSlice(gpa, ",{\"text\":") catch return;
        codec.appendJsonString(&out, gpa, state.text) catch return;
        out.appendSlice(gpa, ",\"selectionBase\":") catch return;
        codec.appendNum(&out, gpa, state.selection.baseOffset) catch return;
        out.appendSlice(gpa, ",\"selectionExtent\":") catch return;
        codec.appendNum(&out, gpa, state.selection.extentOffset) catch return;
        // The caret was placed by us, so it has the downstream affinity, is not
        // directional, and sits outside any composing region.
        out.appendSlice(gpa, ",\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false,\"composingBase\":-1,\"composingExtent\":-1}]}") catch return;

        self.eng.sendPlatformMessage(channels.text_input.name.ptr, out.items);
    }

    /// Reply with a `JSONMethodCodec` error envelope carrying `message`, which
    /// is what the framework logs.
    fn respondError(self: *TextInput, handle: ?*const c.FlutterPlatformMessageResponseHandle, message: []const u8) void {
        var envelope_buf: [256]u8 = undefined;
        self.eng.sendPlatformMessageResponse(handle, codec.jsonError(&envelope_buf, "error", message));
    }

    /// Reply to a method this channel does not implement.
    fn respondUnimplemented(self: *TextInput, handle: ?*const c.FlutterPlatformMessageResponseHandle, method: []const u8) void {
        var message_buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&message_buf, "{s} not implemented", .{method}) catch "not implemented";
        self.respondError(handle, message);
    }
};

/// The arguments of `TextInput.setClient`: the connection id and the
/// configuration, as the `[id, config]` pair the framework's `attach` sends.
const SetClientArgs = struct {
    client_id: i64,
    config: types.TextInputConfiguration,

    fn decode(allocator: std.mem.Allocator, args: std.json.Value) types.Error!SetClientArgs {
        const list = switch (args) {
            .array => |list| list.items,
            else => return error.InvalidJson,
        };
        if (list.len < 2) return error.InvalidValue;
        const client_id = switch (list[0]) {
            .integer => |client_id| client_id,
            else => return error.InvalidValue,
        };
        return .{
            .client_id = client_id,
            .config = try types.TextInputConfiguration.fromJson(allocator, list[1]),
        };
    }

    /// Free the config's list fields. Only valid on a value from `decode`.
    fn deinit(self: *SetClientArgs, allocator: std.mem.Allocator) void {
        self.config.deinit(allocator);
    }
};

fn clampOffset(offset: i64, len: usize) usize {
    if (offset <= 0) return 0;
    const u: usize = @intCast(offset);
    return if (u > len) len else u;
}

test "setClient, insert, and enter" {
    const testing = std.testing;
    testReset();

    var eng = testEngine();
    var ti = TextInput.init(testing.allocator, &eng);
    defer ti.deinit();

    feed(
        &ti,
        "{\"method\":\"TextInput.setClient\",\"args\":[42," ++
            "{\"inputType\":{\"name\":\"TextInputType.text\"},\"inputAction\":\"TextInputAction.done\"}]}",
    );
    try testing.expectEqualStrings("[null]", testResponded());

    testReset();

    // A printable key inserts at the caret and reports the new editing state.
    ti.handleKey('a', 'a', true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[42," ++
            "{\"text\":\"a\",\"selectionBase\":1,\"selectionExtent\":1," ++
            "\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false," ++
            "\"composingBase\":-1,\"composingExtent\":-1}]}",
        testSent(),
    );

    // Enter on a non-multiline field performs the action instead of inserting.
    testReset();
    ti.handleKey(@intCast(xkb.XKB_KEY_Return), 0, true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.performAction\",\"args\":[42,\"TextInputAction.done\"]}",
        testSent(),
    );
}

test "quote is escaped and selection is replaced" {
    const testing = std.testing;
    testReset();

    var eng = testEngine();
    var ti = TextInput.init(testing.allocator, &eng);
    defer ti.deinit();

    feed(&ti, "{\"method\":\"TextInput.setClient\",\"args\":[7,{\"inputType\":{\"name\":\"TextInputType.text\"}}]}");
    feed(&ti, "{\"method\":\"TextInput.setEditingState\",\"args\":{\"text\":\"hello\",\"selectionBase\":0,\"selectionExtent\":5}}");

    testReset();
    ti.handleKey('"', '"', true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[7," ++
            "{\"text\":\"\\\"\",\"selectionBase\":1,\"selectionExtent\":1," ++
            "\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false," ++
            "\"composingBase\":-1,\"composingExtent\":-1}]}",
        testSent(),
    );
}

test "multiline enter inserts a newline, updateConfig applies, read-only ignores" {
    const testing = std.testing;
    testReset();

    var eng = testEngine();
    var ti = TextInput.init(testing.allocator, &eng);
    defer ti.deinit();

    feed(
        &ti,
        "{\"method\":\"TextInput.setClient\",\"args\":[1," ++
            "{\"inputType\":{\"name\":\"TextInputType.multiline\"}," ++
            "\"inputAction\":\"TextInputAction.newline\"}]}",
    );
    try testing.expect(ti.multiline());

    // A multiline field inserts the newline *and* performs the action.
    testReset();
    ti.handleKey(@intCast(xkb.XKB_KEY_Return), 0, true);
    try testing.expectEqualStrings(
        "{\"method\":\"TextInputClient.updateEditingState\",\"args\":[1," ++
            "{\"text\":\"\\n\",\"selectionBase\":1,\"selectionExtent\":1," ++
            "\"selectionAffinity\":\"TextAffinity.downstream\",\"selectionIsDirectional\":false," ++
            "\"composingBase\":-1,\"composingExtent\":-1}]}" ++
            "{\"method\":\"TextInputClient.performAction\",\"args\":[1,\"TextInputAction.newline\"]}",
        testSent(),
    );

    // `updateConfig` carries the whole config as its argument, and read-only
    // fields ignore keys.
    feed(
        &ti,
        "{\"method\":\"TextInput.updateConfig\",\"args\":{" ++
            "\"inputType\":{\"name\":\"TextInputType.multiline\"},\"readOnly\":true," ++
            "\"inputAction\":\"TextInputAction.done\"}}",
    );
    try testing.expect(ti.read_only);
    try testing.expectEqual(types.TextInputAction.done, ti.input_action);

    testReset();
    ti.handleKey('b', 'b', true);
    try testing.expectEqualStrings("", testSent());

    // A config that does not decode is reported, and changes nothing.
    testReset();
    feed(&ti, "{\"method\":\"TextInput.updateConfig\",\"args\":{\"inputAction\":\"TextInputAction.bogus\"}}");
    try testing.expectEqualStrings("[\"error\",\"invalid config\",null]", testResponded());
    try testing.expect(ti.read_only);
    try testing.expect(ti.multiline());

    // Clearing the client forgets the editing state but not the config.
    feed(&ti, "{\"method\":\"TextInput.clearClient\"}");
    try testing.expect(!ti.has_client);
    try testing.expectEqual(@as(usize, 0), ti.text.items.len);
}

fn testEngine() engine.Engine {
    var eng: engine.Engine = undefined;
    eng.handle = null;
    eng.procs = std.mem.zeroes(c.FlutterEngineProcTable);
    eng.procs.SendPlatformMessage = &testSendPlatformMessage;
    eng.procs.SendPlatformMessageResponse = &testSendResponse;
    return eng;
}

var test_sent_buf: [1024]u8 = undefined;
var test_sent_len: usize = 0;
var test_responded_buf: [1024]u8 = undefined;
var test_responded_len: usize = 0;

fn testReset() void {
    test_sent_len = 0;
    test_responded_len = 0;
}

fn testSent() []const u8 {
    return test_sent_buf[0..test_sent_len];
}

fn testResponded() []const u8 {
    return test_responded_buf[0..test_responded_len];
}

fn testAppend(buf: *[1024]u8, len: *usize, data: []const u8) void {
    const n = @min(data.len, buf.len - len.*);
    @memcpy(buf[len.*..][0..n], data[0..n]);
    len.* += n;
}

fn testSendPlatformMessage(_: c.FlutterEngine, message: [*c]const c.FlutterPlatformMessage) callconv(.c) c.FlutterEngineResult {
    const msg = message.*;
    if (msg.message != null) testAppend(&test_sent_buf, &test_sent_len, msg.message[0..msg.message_size]);
    return 0;
}

fn testSendResponse(_: c.FlutterEngine, _: ?*const c.FlutterPlatformMessageResponseHandle, data: [*c]const u8, len: usize) callconv(.c) c.FlutterEngineResult {
    if (data != null) testAppend(&test_responded_buf, &test_responded_len, data[0..len]);
    return 0;
}

fn feed(ti: *TextInput, json: []const u8) void {
    var msg: c.FlutterPlatformMessage = undefined;
    msg.struct_size = @sizeOf(c.FlutterPlatformMessage);
    msg.channel = channels.text_input.name.ptr;
    msg.message = json.ptr;
    msg.message_size = json.len;
    msg.response_handle = @ptrFromInt(1);
    ti.handlePlatformMessage(&msg);
}
