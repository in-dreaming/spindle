const std = @import("std");

/// Creates a process-local identifier whose tag prevents accidental mixing of ID domains.
pub fn GenerationalId(comptime Tag: type) type {
    return packed struct(u64) {
        index: u32,
        generation: u32,

        const Self = @This();
        pub const tag = Tag;
        pub const invalid = Self{ .index = std.math.maxInt(u32), .generation = 0 };

        /// Returns whether this is the reserved invalid value.
        pub fn isValid(self: Self) bool {
            return self.index != invalid.index;
        }

        /// Compares slot then generation, suitable for deterministic ordering.
        pub fn order(_: void, a: Self, b: Self) std.math.Order {
            if (a.index < b.index) return .lt;
            if (a.index > b.index) return .gt;
            return std.math.order(a.generation, b.generation);
        }

        /// Hashes both slot and generation for process-local hash tables only.
        pub fn hash(self: Self) u64 {
            return std.hash.Wyhash.hash(0, std.mem.asBytes(&self));
        }

        /// Formats valid IDs as `index:generation` and invalid IDs as `invalid`.
        pub fn format(self: Self, writer: *std.Io.Writer) std.Io.Writer.Error!void {
            if (!self.isValid()) return writer.writeAll("invalid");
            try writer.print("{d}:{d}", .{ self.index, self.generation });
        }
    };
}

test "generational identifiers distinguish stale values" {
    const Id = GenerationalId(struct {});
    const first = Id{ .index = 4, .generation = 1 };
    const replacement = Id{ .index = 4, .generation = 2 };
    try std.testing.expect(first != replacement);
    try std.testing.expect(first.hash() != replacement.hash());
    try std.testing.expect(!Id.invalid.isValid());
}
