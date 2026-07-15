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

const QueueProducer = struct {
    queue: *spindle.concurrent.MpmcQueue(u32),
    start: u32,
    count: u32,
    fn run(self: @This()) void {
        for (0..self.count) |i| {
            const value = self.start + @as(u32, @intCast(i));
            while (true) {
                self.queue.tryPush(value) catch |err| switch (err) {
                    error.Full => {
                        std.atomic.spinLoopHint();
                        continue;
                    },
                    error.Closed => return,
                };
                break;
            }
        }
    }
};
const QueueConsumer = struct {
    queue: *spindle.concurrent.MpmcQueue(u32),
    seen: []std.atomic.Value(bool),
    consumed: *std.atomic.Value(u32),
    total: u32,
    fn run(self: @This()) void {
        while (self.consumed.load(.acquire) < self.total) {
            const value = self.queue.tryPop() catch |err| switch (err) {
                error.Empty => {
                    std.atomic.spinLoopHint();
                    continue;
                },
                error.Closed => return,
            };
            if (self.seen[value].cmpxchgStrong(false, true, .acq_rel, .monotonic) != null) @panic("duplicate queue value");
            _ = self.consumed.fetchAdd(1, .release);
        }
    }
};

test "mpmc queue conserves bounded concurrent values" {
    const producers = 4;
    const consumers = 4;
    const each: u32 = 20_000;
    const total = producers * each;
    var queue = try spindle.concurrent.MpmcQueue(u32).init(std.testing.allocator, 1024);
    defer queue.deinit(struct {
        fn dispose(_: u32) void {}
    }.dispose);
    const seen = try std.testing.allocator.alloc(std.atomic.Value(bool), total);
    defer std.testing.allocator.free(seen);
    for (seen) |*entry| entry.* = .init(false);
    var consumed: std.atomic.Value(u32) = .init(0);
    var threads: [producers + consumers]std.Thread = undefined;
    for (0..producers) |i| {
        const producer: QueueProducer = .{ .queue = &queue, .start = @as(u32, @intCast(i * each)), .count = each };
        threads[i] = try std.Thread.spawn(.{}, QueueProducer.run, .{producer});
    }
    for (0..consumers) |i| {
        const consumer: QueueConsumer = .{ .queue = &queue, .seen = seen, .consumed = &consumed, .total = total };
        threads[producers + i] = try std.Thread.spawn(.{}, QueueConsumer.run, .{consumer});
    }
    for (threads[0..producers]) |thread| thread.join();
    while (consumed.load(.acquire) != total) std.Thread.yield() catch {};
    queue.close();
    for (threads[producers..]) |thread| thread.join();
    try std.testing.expectEqual(total, consumed.load(.acquire));
    for (seen) |entry| try std.testing.expect(entry.load(.acquire));
}
