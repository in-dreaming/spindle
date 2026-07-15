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

test "concurrent queues distinguish full empty and closed while draining" {
    const Spsc = spindle.concurrent.SpscQueue(u32);
    var spsc = try Spsc.init(std.testing.allocator, 3);
    defer spsc.deinit(struct {
        fn dispose(_: u32) void {}
    }.dispose);
    try spsc.tryPush(1);
    try spsc.tryPush(2);
    try spsc.tryPush(3);
    try std.testing.expectError(error.Full, spsc.tryPush(4));
    try std.testing.expectEqual(@as(u32, 1), try spsc.tryPop());
    try spsc.tryPush(4);
    spsc.close();
    try std.testing.expectError(error.Closed, spsc.tryPush(5));
    try std.testing.expectEqual(@as(u32, 2), try spsc.tryPop());
    try std.testing.expectEqual(@as(u32, 3), try spsc.tryPop());
    try std.testing.expectEqual(@as(u32, 4), try spsc.tryPop());
    try std.testing.expectError(error.Closed, spsc.tryPop());

    const Mpmc = spindle.concurrent.MpmcQueue(u32);
    try std.testing.expectError(error.InvalidCapacity, Mpmc.init(std.testing.allocator, 3));
    var mpmc = try Mpmc.init(std.testing.allocator, 2);
    defer mpmc.deinit(struct {
        fn dispose(_: u32) void {}
    }.dispose);
    try mpmc.tryPush(7);
    try mpmc.tryPush(8);
    try std.testing.expectError(error.Full, mpmc.tryPush(9));
    try std.testing.expectEqual(@as(u32, 7), try mpmc.tryPop());
    try std.testing.expectEqual(@as(u32, 8), try mpmc.tryPop());
    try std.testing.expectError(error.Empty, mpmc.tryPop());
}

test "work stealing deque and intrusive list retain ownership invariants" {
    const Deque = spindle.concurrent.WorkStealingDeque(u8);
    try std.testing.expectError(error.InvalidCapacity, Deque.init(std.testing.allocator, 1));
    var deque = try Deque.init(std.testing.allocator, 2);
    defer deque.deinit(struct {
        fn dispose(_: u8) void {}
    }.dispose);
    try deque.pushBottom(1);
    try deque.pushBottom(2);
    try std.testing.expectError(error.Full, deque.pushBottom(3));
    try std.testing.expectEqual(@as(u8, 1), try deque.stealTop());
    try std.testing.expectEqual(@as(u8, 2), try deque.popBottom());
    var list: spindle.concurrent.IntrusiveList = .{};
    var a: spindle.concurrent.Link = .{};
    var b: spindle.concurrent.Link = .{};
    try list.pushBack(&a);
    try list.pushFront(&b);
    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expect(list.popFront() == &b);
    try list.remove(&a);
    try std.testing.expect(list.isEmpty());
}

test "slab validates capacity, alignment, and double free" {
    const Item = extern struct { value: u64 align(16) };
    const TestSlab = spindle.concurrent.Slab(Item);
    var slab = try TestSlab.init(std.testing.allocator, 2);
    defer slab.deinit(struct {
        fn dispose(_: *Item) void {}
    }.dispose);
    const item = try slab.acquire();
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(item) % @alignOf(Item));
    try slab.release(item);
    try std.testing.expectError(error.DoubleFree, slab.release(item));
}
