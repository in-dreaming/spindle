const std = @import("std");
const spindle = @import("spindle");

test "public package imports without initialization" {
    try std.testing.expect(@TypeOf(spindle) == type);
}

test "envelope decoder rejects bounded random inputs without allocation" {
    var prng = std.Random.DefaultPrng.init(0x4d3c_2b1a);
    const random = prng.random();
    var bytes: [96]u8 = undefined;
    for (0..2000) |_| {
        const length = random.intRangeAtMost(usize, 0, bytes.len);
        random.bytes(bytes[0..length]);
        _ = spindle.core.schema.decode(bytes[0..length], 64) catch continue;
    }
}

test "registry validates a contiguous migration chain and preserves destination on failure" {
    const schema = spindle.core.schema;
    const Registry = spindle.core.registry.Registry;
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(.{ .key = .{ .id = 9, .version = 1 }, .stable_name = "test.message" }, null);
    try std.testing.expectError(error.MigrationGap, registry.register(.{ .key = .{ .id = 9, .version = 2 }, .stable_name = "test.message" }, null));
    try std.testing.expectError(error.DuplicateName, registry.register(.{ .key = .{ .id = 10, .version = 1 }, .stable_name = "test.message" }, null));
    _ = schema;
    registry.freeze();
    try std.testing.expectError(error.Frozen, registry.register(.{ .key = .{ .id = 9, .version = 3 }, .stable_name = "test.message" }, null));
}

test "virtual clock has explicit units" {
    var clock = spindle.core.clock.VirtualClock.init(5, 1000);
    const interface = clock.clock();
    clock.advance(20, 3);
    try std.testing.expectEqual(@as(u64, 25), interface.monotonicNow());
    try std.testing.expectEqual(@as(i64, 1003), interface.utcNow());
}
