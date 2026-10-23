const std = @import("std");

const zart = @import("zart");

/// One row of a `Table`: the name to match, and the value it maps to.
pub fn Entry(comptime T: type) type {
    return struct {
        name: []const u8,
        value: T,
    };
}

pub fn CompiletimeTable(comptime T: type) type {
    return struct {
        const Self = @This();

        table: std.StaticStringMap(T),

        pub fn init(comptime entries: []const Entry(T)) Self {
            const kvs_list = comptime blk: {
                const ListT = [entries.len]struct { []const u8, T };
                var kvs_list: ListT = std.mem.zeroes(ListT);
                for (entries, 0..) |entry, i| {
                    kvs_list[i] = .{ entry.name, entry.value };
                }
                break :blk kvs_list;
            };
            return .{
                .table = .initComptime(kvs_list),
            };
        }

        pub fn get(self: Self, key: []const u8) ?T {
            return self.table.get(key);
        }
    };
}

test "table looks up names, including ones that are prefixes of each other" {
    const testing = std.testing;

    // The longer name comes first, and the shorter one is a strict prefix of it:
    // a key that ends inside an existing compressed path is the tricky case.
    const entries = [_]Entry(u8){
        .{ .name = "flutter/platform_views", .value = 1 },
        .{ .name = "flutter/platform", .value = 2 },
        .{ .name = "TextInput.setSelectionRects", .value = 3 },
        .{ .name = "TextInput.setStyle", .value = 4 },
        .{ .name = "TextInput.setClient", .value = 5 },
    };

    var table = CompiletimeTable(u8).init(&entries);

    try testing.expectEqual(@as(?u8, 1), table.get("flutter/platform_views"));
    try testing.expectEqual(@as(?u8, 2), table.get("flutter/platform"));
    try testing.expectEqual(@as(?u8, 3), table.get("TextInput.setSelectionRects"));
    try testing.expectEqual(@as(?u8, 4), table.get("TextInput.setStyle"));
    try testing.expectEqual(@as(?u8, 5), table.get("TextInput.setClient"));

    // Names that only share a prefix, names that stop short, and the empty name.
    try testing.expectEqual(@as(?u8, null), table.get("flutter"));
    try testing.expectEqual(@as(?u8, null), table.get("flutter/platform_views_2"));
    try testing.expectEqual(@as(?u8, null), table.get("TextInput.set"));
    try testing.expectEqual(@as(?u8, null), table.get(""));
}
