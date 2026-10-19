const std = @import("std");

const table = @import("table.zig");

// TODO:
// add reciever     flutter/platform/SystemSound.play
// add reciever     flutter/platform/exitApplication
// add sender       flutter/platform/requestAppExit
// add sender       flutter/system with {"type": "memoryPressure"}
// add reciever     flutter/mousecursor

/// The wire codec a platform channel speaks. Replies must be encoded with the
/// codec the framework decodes with, otherwise the framework throws while
/// decoding our response (`JSONMethodCodec` and `StandardMethodCodec` use
/// incompatible envelopes).
pub const Codec = enum {
    /// `JSONMethodCodec`: replies are a one-element list (`[<result>]`) on
    /// success or a three-element error list.
    json_method,
    /// `StandardMethodCodec` (the `MethodChannel` default): replies are one
    /// envelope byte followed by a standard-encoded value.
    standard_method,
    /// `JSONMessageCodec` (`BasicMessageChannel`): replies are a bare JSON
    /// value.
    json_message,
};

pub const Channel = struct {
    name: [:0]const u8,
    codec: Codec,
};

/// Outgoing only: the embedder sends raw key events here.
pub const keyevent = Channel{ .name = "flutter/keyevent", .codec = .json_message };

/// `SystemChannels.textInput`.
pub const text_input = Channel{ .name = "flutter/textinput", .codec = .json_method };
/// `SystemChannels.platform`: clipboard, `SystemChrome`, `SystemNavigator`, ...
pub const platform = Channel{ .name = "flutter/platform", .codec = .json_method };
/// `SystemChannels.navigation`.
pub const navigation = Channel{ .name = "flutter/navigation", .codec = .json_method };
/// `SystemChannels.skia`.
pub const skia = Channel{ .name = "flutter/skia", .codec = .json_method };
/// `SystemChannels.undoManager`.
pub const undo_manager = Channel{ .name = "flutter/undomanager", .codec = .json_method };
/// `SystemChannels.scribe`.
pub const scribe = Channel{ .name = "flutter/scribe", .codec = .json_method };

/// `SystemChannels.keyboard`: pressed-key state synchronisation.
pub const keyboard = Channel{ .name = "flutter/keyboard", .codec = .standard_method };
/// `SystemChannels.mouseCursor`.
pub const mouse_cursor = Channel{ .name = "flutter/mousecursor", .codec = .standard_method };
/// `SystemChannels.backGesture`.
pub const back_gesture = Channel{ .name = "flutter/backgesture", .codec = .standard_method };
/// `SystemChannels.processText`.
pub const process_text = Channel{ .name = "flutter/processtext", .codec = .standard_method };
/// `SystemChannels.spellCheck`.
pub const spell_check = Channel{ .name = "flutter/spellcheck", .codec = .standard_method };
/// `SystemChannels.restoration`.
pub const restoration = Channel{ .name = "flutter/restoration", .codec = .standard_method };
/// `SystemChannels.deferredComponent`.
pub const deferred_component = Channel{ .name = "flutter/deferredcomponent", .codec = .standard_method };
/// `SystemChannels.menu`.
pub const menu = Channel{ .name = "flutter/menu", .codec = .standard_method };
/// `SystemChannels.platform_views`.
pub const platform_views = Channel{ .name = "flutter/platform_views", .codec = .standard_method };
/// `SystemChannels.platform_views_2`.
pub const platform_views_2 = Channel{ .name = "flutter/platform_views_2", .codec = .standard_method };
/// `SystemChannels.sensitiveContent`.
pub const sensitive_content = Channel{ .name = "flutter/sensitivecontent", .codec = .standard_method };

/// The handler that answers a channel's messages.
pub const Handler = enum { text_input, platform };

/// What to do with a message that arrives on a channel: which handler answers
/// it, and the codec the framework decodes the reply with.
pub const Route = struct {
    /// The handler that answers, or null for a channel we only acknowledge.
    handler: ?Handler = null,
    codec: Codec = .standard_method,
};

/// Every channel we treat differently from the default: the ones that speak
/// `JSONMethodCodec`, two of which we implement. Anything not listed here is not
/// implemented and speaks `StandardMethodCodec`, which is the `MethodChannel`
/// default. Each row takes its codec from the channel constant above it, so the
/// two never drift apart.
pub const routes = [_]table.Entry(Route){
    .{ .name = text_input.name, .value = .{ .handler = .text_input, .codec = text_input.codec } },
    .{ .name = platform.name, .value = .{ .handler = .platform, .codec = platform.codec } },
    .{ .name = navigation.name, .value = .{ .codec = navigation.codec } },
    .{ .name = skia.name, .value = .{ .codec = skia.codec } },
    .{ .name = undo_manager.name, .value = .{ .codec = undo_manager.codec } },
    .{ .name = scribe.name, .value = .{ .codec = scribe.codec } },
};

test "routes carry the handler and codec of each channel the framework sends" {
    const testing = std.testing;

    var routes_table = table.Table(Route).init(testing.allocator, &routes);
    defer routes_table.deinit();

    // The two channels we implement speak `JSONMethodCodec`.
    const text_input_route = routes_table.get(text_input.name).?;
    try testing.expectEqual(Handler.text_input, text_input_route.handler.?);
    try testing.expectEqual(Codec.json_method, text_input_route.codec);

    const platform_route = routes_table.get(platform.name).?;
    try testing.expectEqual(Handler.platform, platform_route.handler.?);
    try testing.expectEqual(Codec.json_method, platform_route.codec);

    // A JSON channel we do not implement still carries its codec, so that the
    // framework can decode the null reply we send it.
    const undo_route = routes_table.get(undo_manager.name).?;
    try testing.expectEqual(@as(?Handler, null), undo_route.handler);
    try testing.expectEqual(Codec.json_method, undo_route.codec);

    // Anything else is not ours to route.
    try testing.expectEqual(@as(?Route, null), routes_table.get("flutter/bogus"));
}
