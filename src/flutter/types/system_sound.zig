const std = @import("std");

pub const SystemSoundType = enum {
    /// A short indication that a button was pressed.
    click,

    /// A short indication that a picker value was changed.
    ///
    /// This is ignored on all platforms except iOS.
    tick,

    /// A short system alert sound indicating the need for user attention.
    ///
    /// Desktop platforms are the only platforms that support a system alert
    /// sound, so on mobile platforms (Android, iOS), this will be ignored. The
    /// web platform does not support playing any sounds, so this will be
    /// ignored on the web as well.
    alert,

    /// Placeholder for an unknown value
    unknown,

    pub fn fromString(value: []const u8) SystemSoundType {
        if (std.mem.eql(u8, value, "click")) {
            return .click;
        } else if (std.mem.eql(u8, value, "alert")) {
            return .alert;
        } else if (std.mem.eql(u8, value, "tick")) {
            return .tick;
        } else {
            return .unknown;
        }
    }
};
