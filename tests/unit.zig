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

const TaskProbe = struct {
    value: *std.atomic.Value(u32),
    fn run(task: *spindle.executor.Task) void {
        const self: *TaskProbe = @ptrCast(@alignCast(task.context.?));
        _ = self.value.fetchAdd(1, .acq_rel);
    }
};

test "inline executor executes once and rejects duplicate submission" {
    var value: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &value };
    var task = spindle.executor.Task.init(TaskProbe.run, &probe);
    var executor: spindle.executor.InlineExecutor = .{};
    try executor.submit(&task, .{});
    try std.testing.expectEqual(@as(u32, 1), value.load(.acquire));
    try std.testing.expectError(error.DuplicateSubmission, executor.submit(&task, .{}));
    executor.shutdown(.drain);
    var rejected = spindle.executor.Task.init(TaskProbe.run, &probe);
    try std.testing.expectError(error.Shutdown, executor.submit(&rejected, .{}));
}

test "pump executor honors a task count drain budget" {
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 4);
    defer pump.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &value };
    var first = spindle.executor.Task.init(TaskProbe.run, &probe);
    var second = spindle.executor.Task.init(TaskProbe.run, &probe);
    try pump.submit(&first, .{});
    try pump.submit(&second, .{});
    try std.testing.expectEqual(@as(usize, 1), pump.drain(1));
    try std.testing.expectEqual(@as(u32, 1), value.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), pump.drain(1));
    try std.testing.expectEqual(@as(u32, 2), value.load(.acquire));
}

test "fixed pool executes on a dedicated worker and joins on shutdown" {
    var pool = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 4);
    defer pool.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &value };
    var task = spindle.executor.Task.init(TaskProbe.run, &probe);
    try pool.submit(&task, .{});
    try task.wait();
    try std.testing.expectEqual(@as(u32, 1), value.load(.acquire));
}

test "frame arena refuses reuse while its epoch is in flight" {
    var frames = spindle.executor.FrameArena.init(std.testing.allocator);
    defer frames.deinit();
    const in_flight = frames.counter();
    in_flight.add(1);
    try frames.rotate();
    try frames.rotate();
    try std.testing.expectError(error.FrameInFlight, frames.rotate());
    in_flight.complete();
    try frames.rotate();
}

const FailingTaskProbe = struct {
    fn run(task: *spindle.executor.Task) void {
        task.fail();
    }
};

test "scope observes task failures and cancel-on-first-error joins children" {
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 4);
    defer pump.deinit();
    var scope = spindle.executor.Scope.init(pump.executor(), .cancel_on_first_error);
    var failed = spindle.executor.Task.init(FailingTaskProbe.run, null);
    var pending = spindle.executor.Task.init(FailingTaskProbe.run, null);
    try scope.spawn(&failed);
    try scope.spawn(&pending);
    _ = pump.drain(1);
    try std.testing.expectError(error.TaskFailed, scope.wait());
    try std.testing.expectEqual(spindle.executor.TaskState.cancelled, pending.status());
}

test "executor registry rejects stale slot generations" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var inline_executor: spindle.executor.InlineExecutor = .{};
    const id = try registry.register(inline_executor.executor());
    try std.testing.expect(registry.resolve(id) != null);
    try std.testing.expect(registry.unregister(id));
    try std.testing.expect(registry.resolve(id) == null);
}

test "task handles become stale after terminal task reuse" {
    var value: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &value };
    var task = spindle.executor.Task.init(TaskProbe.run, &probe);
    var executor: spindle.executor.InlineExecutor = .{};
    const handle = task.handle();
    try executor.submit(&task, .{});
    try task.reset();
    try std.testing.expectError(error.StaleHandle, handle.status());
    try std.testing.expect(!handle.cancel());
}

test "tracked detached work is cancelled and joined by its explicit owner" {
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 2);
    defer pump.deinit();
    var tracker = spindle.executor.DetachedTracker.init(std.testing.allocator);
    defer tracker.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &value };
    var handle = try spindle.executor.submitTrackedDetached(&tracker, std.testing.allocator, pump.executor(), TaskProbe.run, &probe);
    tracker.shutdown();
    pump.shutdown(.cancel_pending);
    try handle.wait();
    try std.testing.expectEqual(spindle.executor.TaskState.cancelled, try handle.taskHandle().status());
    handle.deinit();
}

const WorkerIdentityProbe = struct {
    pool: *spindle.executor.FixedPool,
    observed: *std.atomic.Value(bool),
    fn run(task: *spindle.executor.Task) void {
        const self: *WorkerIdentityProbe = @ptrCast(@alignCast(task.context.?));
        self.observed.store(self.pool.isWorkerThread(), .release);
    }
};

test "fixed pool identifies its own worker thread" {
    var pool = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 2);
    defer pool.deinit();
    var observed: std.atomic.Value(bool) = .init(false);
    var probe = WorkerIdentityProbe{ .pool = &pool, .observed = &observed };
    var task = spindle.executor.Task.init(WorkerIdentityProbe.run, &probe);
    try pool.submit(&task, .{});
    try task.wait();
    try std.testing.expect(observed.load(.acquire));
}
