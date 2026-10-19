const std = @import("std");

pub const AppExitType = enum {
    cancelable,
    required,
    unknown,

    pub fn fromString(value: []const u8) AppExitType {
        if (std.mem.eql(u8, value, "cancelable")) {
            return .cancelable;
        } else if (std.mem.eql(u8, value, "required")) {
            return .required;
        } else {
            return .unknown;
        }
    }
};

pub const AppExitResponse = enum {
    cancel,
    exit,

    pub fn fromString(value: []const u8) AppExitResponse {
        if (std.mem.eql(u8, value, "cancel")) {
            return .cancel;
        } else if (std.mem.eql(u8, value, "exit")) {
            return .exit;
        } else {
            return .exit;
        }
    }
};
