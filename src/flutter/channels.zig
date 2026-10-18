const std = @import("std");

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

/// Channels that speak `JSONMethodCodec`. Every other channel defaults to
/// `StandardMethodCodec`, which is the `MethodChannel` default.
const json_channels = [_][]const u8{
    text_input.name,
    platform.name,
    navigation.name,
    skia.name,
    undo_manager.name,
    scribe.name,
};

/// The codec the framework decodes a channel's replies with.
pub fn codecFor(name: []const u8) Codec {
    for (json_channels) |json_name| {
        if (std.mem.eql(u8, name, json_name)) return .json_method;
    }
    return .standard_method;
}
