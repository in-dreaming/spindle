const std = @import("std");
const build_options = @import("build_options");
const spindle = @import("spindle");

test "stress harness has a bounded reproducible iteration count" {
    _ = spindle;
    try std.testing.expect(build_options.iterations > 0);
}

const Worker = struct {
    generator: *spindle.core.stable_id.Generator,
    output: []spindle.core.StableId,
    seed: u64,

    fn run(worker: Worker) void {
        var prng = std.Random.DefaultPrng.init(worker.seed);
        const random = prng.random();
        for (worker.output) |*id| id.* = worker.generator.next(50_000, random);
    }
};

fn lessThan(_: void, lhs: spindle.core.StableId, rhs: spindle.core.StableId) bool {
    return lhs.high < rhs.high or (lhs.high == rhs.high and lhs.low < rhs.low);
}

test "stable id generator produces one million unique concurrent identifiers" {
    const count = 1_000_000;
    const workers = 8;
    var output = try std.testing.allocator.alloc(spindle.core.StableId, count);
    defer std.testing.allocator.free(output);
    var generator: spindle.core.stable_id.Generator = .{};
    var threads: [workers]std.Thread = undefined;
    for (&threads, 0..) |*thread, index| {
        const start = index * (count / workers);
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{Worker{
            .generator = &generator,
            .output = output[start .. start + count / workers],
            .seed = @intCast(index + 1),
        }});
    }
    for (threads) |thread| thread.join();
    std.sort.pdq(spindle.core.StableId, output, {}, lessThan);
    for (output[1..], output[0 .. output.len - 1]) |next, previous| {
        try std.testing.expect(!std.meta.eql(next, previous));
    }
}
