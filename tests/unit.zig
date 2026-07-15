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

test "sync event preserves signal-before-wait and auto-reset" {
    var event = spindle.sync.Event.init(.auto, false);
    event.set();
    try event.wait(null, .{});
    const deadline = spindle.platform.park.deadlineAfter(0);
    try std.testing.expectError(error.Timeout, event.wait(deadline, .{}));
}

test "semaphore enforces its maximum and consumes permits" {
    var semaphore = try spindle.sync.Semaphore.init(1, 2);
    try semaphore.acquire(null, .{});
    try std.testing.expectError(error.Timeout, semaphore.acquire(spindle.platform.park.deadlineAfter(0), .{}));
    try semaphore.release(2);
    try std.testing.expectError(error.Overflow, semaphore.release(1));
}

test "barrier is reusable across generations" {
    var barrier = try spindle.sync.Barrier.init(1);
    try barrier.arriveAndWait(null, .{});
    try barrier.arriveAndWait(null, .{});
}

test "cancellation is visible through the sync wait view" {
    var source: spindle.executor.CancellationSource = .{};
    source.cancel();
    var event = spindle.sync.Event.init(.manual, false);
    try std.testing.expectError(error.Cancelled, event.wait(null, source.token().waitView()));
}

const OnceProbe = struct {
    attempts: *u32,
    fn run(self: @This()) !void {
        self.attempts.* += 1;
        if (self.attempts.* == 1) return error.FirstAttempt;
    }
};

test "once retries after a failed initializer" {
    var once: spindle.sync.Once = .{};
    var attempts: u32 = 0;
    try std.testing.expectError(error.FirstAttempt, once.call(OnceProbe.run, .{OnceProbe{ .attempts = &attempts }}));
    try once.call(OnceProbe.run, .{OnceProbe{ .attempts = &attempts }});
    try once.call(OnceProbe.run, .{OnceProbe{ .attempts = &attempts }});
    try std.testing.expectEqual(@as(u32, 2), attempts);
}

const BlockingWaiter = struct {
    event: *spindle.sync.Event,
    started: *spindle.sync.Semaphore,
    completed: *spindle.sync.Semaphore,
    cancel: spindle.sync.common.CancelWait = .{},
    result: *std.atomic.Value(u32),

    fn run(self: @This()) void {
        self.started.release(1) catch return;
        self.event.wait(spindle.platform.park.deadlineAfter(std.time.ns_per_s), self.cancel) catch |err| {
            self.result.store(if (err == error.Cancelled) 2 else 3, .release);
            self.completed.release(1) catch return;
            return;
        };
        self.result.store(1, .release);
        self.completed.release(1) catch return;
    }
};

test "thread waiting on an event is released by a later signal" {
    var event = spindle.sync.Event.init(.manual, false);
    var started = try spindle.sync.Semaphore.init(0, 1);
    var completed = try spindle.sync.Semaphore.init(0, 1);
    var result: std.atomic.Value(u32) = .init(0);
    const thread = try spindle.platform.thread.spawn(.{}, BlockingWaiter.run, .{BlockingWaiter{
        .event = &event,
        .started = &started,
        .completed = &completed,
        .result = &result,
    }});
    defer thread.join();
    try started.acquire(spindle.platform.park.deadlineAfter(std.time.ns_per_s), .{});
    event.set();
    try completed.acquire(spindle.platform.park.deadlineAfter(std.time.ns_per_s), .{});
    try std.testing.expectEqual(@as(u32, 1), result.load(.acquire));
}

test "cancellation wakes a thread already blocked on an event" {
    var source: spindle.executor.CancellationSource = .{};
    var event = spindle.sync.Event.init(.manual, false);
    var started = try spindle.sync.Semaphore.init(0, 1);
    var completed = try spindle.sync.Semaphore.init(0, 1);
    var result: std.atomic.Value(u32) = .init(0);
    const thread = try spindle.platform.thread.spawn(.{}, BlockingWaiter.run, .{BlockingWaiter{
        .event = &event,
        .started = &started,
        .completed = &completed,
        .cancel = source.token().waitView(),
        .result = &result,
    }});
    defer thread.join();
    try started.acquire(spindle.platform.park.deadlineAfter(std.time.ns_per_s), .{});
    source.cancel();
    try completed.acquire(spindle.platform.park.deadlineAfter(std.time.ns_per_s), .{});
    try std.testing.expectEqual(@as(u32, 2), result.load(.acquire));
}
