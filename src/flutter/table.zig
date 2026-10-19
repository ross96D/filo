const std = @import("std");

const zart = @import("zart");

/// One row of a `Table`: the name to match, and the value it maps to.
pub fn Entry(comptime T: type) type {
    return struct {
        name: []const u8,
        value: T,
    };
}

/// A `name → value` table for the fixed set of names the framework sends.
///
/// Backed by a `zart` adaptive radix tree, which copies the key bytes it needs
/// into its own nodes, so a `name` only has to live until `init` returns. Values
/// are stored by value. Rows are never removed (upstream's `delete` does not
/// demote nodes yet, and is documented as able to crash), so a table is built
/// once and only read afterwards.
pub fn Table(comptime T: type) type {
    return struct {
        const Self = @This();

        tree: zart.Tree(T),

        /// Build the table from `entries`. Infallible by design: `zart` treats an
        /// allocation failure as unreachable, so this panics rather than
        /// returning an error, which is fine for a table built once at startup.
        pub fn init(allocator: std.mem.Allocator, entries: []const Entry(T)) Self {
            var tree = zart.Tree(T).init(allocator);
            for (entries) |entry| _ = tree.set(entry.name, entry.value);
            return .{ .tree = tree };
        }

        pub fn deinit(self: *Self) void {
            self.tree.deinit();
        }

        /// The value `name` maps to, or null if the table does not list it.
        pub fn get(self: *Self, name: []const u8) ?T {
            return self.tree.get(name);
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

    var table = Table(u8).init(testing.allocator, &entries);
    defer table.deinit();

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
