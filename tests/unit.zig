const std = @import("std");
const spindle = @import("spindle");
const checkpoint_workflow = @import("fixtures/checkpoint_workflow.zig");

test "workflow worker checkpoints terminal decision state" {
    const Event = spindle.workflow.event.Event;
    const Payload = spindle.workflow.event.Payload;
    const events = [_]Event{
        .{ .sequence = 1, .kind = spindle.workflow.event.Kind.started, .utc_ms = 1, .payload = Payload{ .schema = checkpoint_workflow.schema, .bytes = "" } },
        .{ .sequence = 2, .kind = spindle.workflow.event.Kind.cancellation_requested, .utc_ms = 2, .payload = Payload{ .schema = checkpoint_workflow.schema, .bytes = "" } },
    };
    var command_storage: [4]spindle.workflow.command.Command = undefined;
    const result = try spindle.workflow.worker.processDecisions(checkpoint_workflow.definition, .{ .high = 1, .low = 2 }, "", 0, &events, &command_storage);
    try std.testing.expectEqual(spindle.workflow.instance.Status.cancelled, result.status);
    try std.testing.expect(result.optional_snapshot != null);
    try std.testing.expect(spindle.workflow.snapshot.verify(result.optional_snapshot.?));
}

test "workflow snapshot tail and full history reach identical output" {
    const Event = spindle.workflow.event.Event;
    const payload = spindle.workflow.event.Payload{ .schema = login_workflow.event_schema, .bytes = "" };
    const history = [_]Event{
        .{ .sequence = 1, .kind = spindle.workflow.event.Kind.started, .utc_ms = 1, .payload = payload },
        .{ .sequence = 2, .kind = spindle.workflow.event.Kind.activity_completed, .utc_ms = 2, .payload = payload },
    };
    var full_commands: [4]spindle.workflow.command.Command = undefined;
    const full = try spindle.workflow.worker.processDecisions(login_workflow.definition, .{ .high = 4, .low = 5 }, login_workflow.idle, 0, &history, &full_commands);
    var tail_commands: [2]spindle.workflow.command.Command = undefined;
    const tail = try spindle.workflow.worker.processDecisions(login_workflow.definition, .{ .high = 4, .low = 5 }, login_workflow.waiting, 1, history[1..], &tail_commands);
    try std.testing.expectEqualStrings(full.state, tail.state);
    try std.testing.expectEqual(full.status, tail.status);
    try std.testing.expectEqual(full.commands[1].kind, tail.commands[0].kind);
    try std.testing.expectEqual(full.commands[1].payload.schema, tail.commands[0].payload.schema);
    try std.testing.expectEqualStrings(full.commands[1].payload.bytes, tail.commands[0].payload.bytes);
}
const login_workflow = @import("fixtures/login_workflow.zig");

test "workflow login v3 fixture replays normal reconnect timeout and compensation commands" {
    const workflow = spindle.workflow;
    const Event = workflow.event.Event;
    const Payload = workflow.event.Payload;
    const commands = workflow.command.Command;
    const empty = Payload{ .schema = login_workflow.event_schema, .bytes = "" };
    const history = [_]Event{
        .{ .sequence = 1, .kind = workflow.event.Kind.started, .utc_ms = 100, .payload = empty },
        .{ .sequence = 2, .kind = workflow.event.Kind.activity_completed, .utc_ms = 101, .payload = empty },
    };
    const recorded = [_]workflow.replay.CommandEvent{
        .{ .input_sequence = 1, .commands = &.{.{ .sequence = 1, .kind = workflow.command.Kind.schedule_activity, .payload = .{ .schema = login_workflow.command_schema, .bytes = "authenticate" } }} },
        .{ .input_sequence = 2, .commands = &.{.{ .sequence = 1, .kind = workflow.command.Kind.complete, .payload = .{ .schema = login_workflow.command_schema, .bytes = "logged-in" } }} },
    };
    var storage: [4]commands = undefined;
    const result = try workflow.replay.verify(login_workflow.definition, login_workflow.idle, null, &history, &recorded, &storage, &.{});
    try std.testing.expectEqual(workflow.instance.Status.completed, result.status);
    var second_storage: [4]commands = undefined;
    const replayed = try workflow.replay.verify(login_workflow.definition, login_workflow.idle, null, &history, &recorded, &second_storage, &.{});
    try std.testing.expectEqual(result, replayed);

    const reconnect_history = [_]Event{
        .{ .sequence = 1, .kind = workflow.event.Kind.started, .utc_ms = 100, .payload = empty },
        .{ .sequence = 2, .kind = workflow.event.Kind.signal_received, .utc_ms = 101, .payload = empty },
        .{ .sequence = 3, .kind = workflow.event.Kind.activity_completed, .utc_ms = 102, .payload = empty },
    };
    const reconnected = [_]workflow.replay.CommandEvent{
        recorded[0],
        .{ .input_sequence = 2, .commands = &.{} },
        .{ .input_sequence = 3, .commands = recorded[1].commands },
    };
    try std.testing.expectEqual(workflow.instance.Status.completed, (try workflow.replay.verify(login_workflow.definition, login_workflow.idle, null, &reconnect_history, &reconnected, &storage, &.{})).status);

    const failure_history = [_]Event{
        .{ .sequence = 1, .kind = workflow.event.Kind.started, .utc_ms = 100, .payload = empty },
        .{ .sequence = 2, .kind = workflow.event.Kind.activity_failed, .utc_ms = 102, .payload = empty },
    };
    const failed = [_]workflow.replay.CommandEvent{
        recorded[0],
        .{ .input_sequence = 2, .commands = &.{.{ .sequence = 1, .kind = workflow.command.Kind.compensate, .payload = .{ .schema = login_workflow.command_schema, .bytes = "revoke-session" } }} },
    };
    try std.testing.expectEqual(workflow.instance.Status.failed, (try workflow.replay.verify(login_workflow.definition, login_workflow.idle, null, &failure_history, &failed, &storage, &.{})).status);
}

test "workflow verifier detects command mutation and retry is deterministic" {
    const workflow = spindle.workflow;
    const Event = workflow.event.Event;
    const Payload = workflow.event.Payload;
    const Command = workflow.command.Command;
    const history = [_]Event{.{ .sequence = 1, .kind = workflow.event.Kind.started, .utc_ms = 0, .payload = Payload{ .schema = login_workflow.event_schema, .bytes = "" } }};
    const mutated = [_]workflow.replay.CommandEvent{.{ .input_sequence = 1, .commands = &.{.{ .sequence = 1, .kind = workflow.command.Kind.complete, .payload = .{ .schema = login_workflow.command_schema, .bytes = "wrong" } }} }};
    var storage: [2]Command = undefined;
    try std.testing.expectError(error.CommandMismatch, workflow.replay.verify(login_workflow.definition, login_workflow.idle, null, &history, &mutated, &storage, &.{}));
    const policy = workflow.retry.Policy{ .initial_backoff_ms = 10, .max_backoff_ms = 25, .max_attempts = 3, .jitter_percent = 20, .non_retryable = &.{9} };
    try std.testing.expectEqual(workflow.retry.delayMs(policy, 3, 17), workflow.retry.delayMs(policy, 3, 17));
    try std.testing.expect(!workflow.retry.shouldRetry(policy, 1, .{ .kind = .application, .code = 9, .message = "permanent" }));
}

test "workflow registry snapshots migrations and instance state transitions are explicit" {
    const workflow = spindle.workflow;
    var registry = workflow.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(login_workflow.definition);
    try std.testing.expectError(error.DuplicateVersion, registry.register(login_workflow.definition));
    registry.freeze();
    try std.testing.expectError(error.Frozen, registry.register(login_workflow.definition));
    try std.testing.expectError(error.UnknownVersion, registry.find(login_workflow.definition_id, 99));

    const id = spindle.core.StableId{ .high = 1, .low = 2 };
    const saved = workflow.snapshot.Snapshot{ .workflow_id = id, .event_sequence = 7, .definition_version = 3, .state = "waiting", .checksum = workflow.snapshot.checksum(id, 7, 3, "waiting") };
    try std.testing.expect(workflow.snapshot.verify(saved));
    const header = workflow.snapshot.encodeHeader(saved);
    try std.testing.expectEqual(@as(u8, 0), header[0]);
    try std.testing.expectEqual(@as(u8, 2), header[15]);
    try std.testing.expect(!workflow.snapshot.verify(.{ .workflow_id = id, .event_sequence = 7, .definition_version = 3, .state = "changed", .checksum = saved.checksum }));

    const step = struct {
        fn apply(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
            const value = try allocator.alloc(u8, input.len + 1);
            @memcpy(value[0..input.len], input);
            value[input.len] = '!';
            return value;
        }
    }.apply;
    const migrated = try workflow.migration.migrate(std.testing.allocator, &.{.{ .from_version = 2, .to_version = 3, .apply = step }}, 2, 3, "state");
    defer std.testing.allocator.free(migrated);
    try std.testing.expectEqualStrings("state!", migrated);
    try std.testing.expectError(error.MigrationGap, workflow.migration.migrate(std.testing.allocator, &.{}, 2, 3, "state"));

    var value = workflow.instance.Instance{ .id = id, .definition_id = login_workflow.definition_id, .definition_version = 3, .created_utc_ms = 1, .updated_utc_ms = 1 };
    try std.testing.expectError(error.InvalidSequence, value.applySequence(2, 2));
    try value.applySequence(1, 2);
    try value.finish(.completed, 3);
    try std.testing.expectError(error.TerminalInstance, value.applySequence(2, 4));
}

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

const WorkStealingSpawnProbe = struct {
    executor: *spindle.executor.WorkStealingExecutor,
    children: []spindle.executor.Task,
    value: *std.atomic.Value(u32),
    fn parent(task: *spindle.executor.Task) void {
        const self: *WorkStealingSpawnProbe = @ptrCast(@alignCast(task.context.?));
        for (self.children) |*child_task| self.executor.submit(child_task, .{}) catch @panic("work-stealing submission failed");
    }
    fn child(task: *spindle.executor.Task) void {
        const self: *WorkStealingSpawnProbe = @ptrCast(@alignCast(task.context.?));
        _ = self.value.fetchAdd(1, .acq_rel);
    }
};

test "work-stealing executor runs local overflow through bounded injection and joins workers" {
    var executor = try spindle.executor.WorkStealingExecutor.init(std.testing.allocator, .{ .workers = 2, .local_capacity = 2, .injection_capacity = 16, .urgent_capacity = 2 });
    defer executor.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var children: [6]spindle.executor.Task = undefined;
    var probe = WorkStealingSpawnProbe{ .executor = &executor, .children = &children, .value = &value };
    for (&children) |*child| child.* = spindle.executor.Task.init(WorkStealingSpawnProbe.child, &probe);
    var parent = spindle.executor.Task.init(WorkStealingSpawnProbe.parent, &probe);
    try executor.submit(&parent, .{});
    try parent.wait();
    for (&children) |*child| try child.wait();
    try std.testing.expectEqual(@as(u32, 6), value.load(.acquire));
}

test "deterministic executor replay rejects mismatched task identities" {
    var recorded = spindle.executor.DeterministicExecutor.init(std.testing.allocator);
    defer recorded.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &value };
    var task = spindle.executor.Task.init(TaskProbe.run, &probe);
    try recorded.submitWithId(&task, 42);
    try recorded.run();
    var log = try recorded.recordLog();
    defer log.deinit(std.testing.allocator);
    var replay = try spindle.executor.DeterministicExecutor.initReplay(std.testing.allocator, &log);
    defer replay.deinit();
    var divergent = spindle.executor.Task.init(TaskProbe.run, &probe);
    try std.testing.expectError(error.ReplayMismatch, replay.submitWithId(&divergent, 7));
}

const PriorityProbe = struct {
    executor: *spindle.executor.WorkStealingExecutor,
    high: []spindle.executor.Task,
    background: *spindle.executor.Task,
    high_done: *std.atomic.Value(u32),
    background_observed: *std.atomic.Value(u32),
    fn parent(task: *spindle.executor.Task) void {
        const self: *PriorityProbe = @ptrCast(@alignCast(task.context.?));
        self.executor.submit(self.background, .{}) catch @panic("background submission failed");
        for (self.high) |*high_task| self.executor.submit(high_task, .{}) catch @panic("high submission failed");
    }
    fn highTask(task: *spindle.executor.Task) void {
        const self: *PriorityProbe = @ptrCast(@alignCast(task.context.?));
        _ = self.high_done.fetchAdd(1, .acq_rel);
    }
    fn backgroundTask(task: *spindle.executor.Task) void {
        const self: *PriorityProbe = @ptrCast(@alignCast(task.context.?));
        self.background_observed.store(self.high_done.load(.acquire), .release);
    }
};

test "work-stealing priority aging bounds background starvation" {
    var executor = try spindle.executor.WorkStealingExecutor.init(std.testing.allocator, .{ .workers = 1, .local_capacity = 64, .injection_capacity = 64, .urgent_capacity = 2, .high_skip_limit = 3, .normal_skip_limit = 5 });
    defer executor.deinit();
    var high_done: std.atomic.Value(u32) = .init(0);
    var background_observed: std.atomic.Value(u32) = .init(99);
    var high: [12]spindle.executor.Task = undefined;
    var background = spindle.executor.Task.init(PriorityProbe.backgroundTask, null);
    var probe = PriorityProbe{ .executor = &executor, .high = &high, .background = &background, .high_done = &high_done, .background_observed = &background_observed };
    background.context = &probe;
    background.priority = .low;
    for (&high) |*high_task| {
        high_task.* = spindle.executor.Task.init(PriorityProbe.highTask, &probe);
        high_task.priority = .high;
    }
    var parent = spindle.executor.Task.init(PriorityProbe.parent, &probe);
    try executor.submit(&parent, .{});
    try background.wait();
    try std.testing.expect(background_observed.load(.acquire) <= 5);
}

const ParallelProbe = struct {
    total: *std.atomic.Value(usize),
    fn run(self: *@This(), begin: usize, end: usize, _: spindle.executor.CancellationToken) !void {
        _ = self.total.fetchAdd(end - begin, .acq_rel);
    }
};

test "parallel algorithms use bounded chunks and match serial references" {
    var pool = try spindle.executor.FixedPool.init(std.testing.allocator, 2, 32);
    defer pool.deinit();
    var total: std.atomic.Value(usize) = .init(0);
    var probe = ParallelProbe{ .total = &total };
    try spindle.parallel.forRange(std.testing.allocator, pool.executor(), .{ .end = 137 }, .{ .grain = 11 }, &probe, ParallelProbe.run);
    try std.testing.expectEqual(@as(usize, 137), total.load(.acquire));
    const add = struct {
        fn run(a: u32, b: u32) u32 {
            return a + b;
        }
    }.run;
    const input = [_]u32{ 1, 2, 3, 4 };
    try std.testing.expectEqual(@as(u32, 10), spindle.parallel.reduce.reduce(std.testing.allocator, pool.executor(), u32, &input, 0, .{ .deterministic = true }, add));
    var scanned: [4]u32 = undefined;
    try spindle.parallel.scan.exclusive(std.testing.allocator, pool.executor(), u32, &input, &scanned, 0, add);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 3, 6 }, &scanned);
}

test "completion schedules its continuation on the selected executor" {
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 2);
    defer pump.deinit();
    var observed: std.atomic.Value(u32) = .init(0);
    var probe = TaskProbe{ .value = &observed };
    var continuation = spindle.executor.Task.init(TaskProbe.run, &probe);
    var completion = spindle.io_adapter.Completion(u32).init(99);
    try completion.then(pump.executor(), &continuation);
    try completion.finish(7);
    _ = pump.drain(1);
    try std.testing.expectEqual(@as(u32, 7), try completion.wait());
    try std.testing.expectEqual(@as(u32, 1), observed.load(.acquire));
}

test "bounded pipeline reports backpressure and drains values" {
    var storage: [1]u32 = undefined;
    var pipe = spindle.parallel.pipeline.Bounded(u32).init(&storage);
    try pipe.push(4);
    try std.testing.expectError(error.Backpressure, pipe.push(5));
    try std.testing.expectEqual(@as(u32, 4), try pipe.pop());
    pipe.close();
    try std.testing.expectError(error.Closed, pipe.pop());
}

test "parallel scan and stable sort match serial golden results" {
    var pool = try spindle.executor.FixedPool.init(std.testing.allocator, 2, 32);
    defer pool.deinit();
    const add = struct {
        fn run(a: u32, b: u32) u32 {
            return a + b;
        }
    }.run;
    const input = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9 };
    var exclusive: [input.len]u32 = undefined;
    var inclusive: [input.len]u32 = undefined;
    try spindle.parallel.scan.exclusive(std.testing.allocator, pool.executor(), u32, &input, &exclusive, 0, add);
    try spindle.parallel.scan.inclusive(std.testing.allocator, pool.executor(), u32, &input, &inclusive, add);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 3, 6, 10, 15, 21, 28, 36 }, &exclusive);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 3, 6, 10, 15, 21, 28, 36, 45 }, &inclusive);
    var values = [_]u32{ 4, 1, 3, 3, 2, 5, 0 };
    try spindle.parallel.sort.stable(std.testing.allocator, pool.executor(), u32, &values, {}, std.sort.asc(u32));
    try std.testing.expectEqualSlices(u32, &[_]u32{ 0, 1, 2, 3, 3, 4, 5 }, &values);
}

const FileIoProbe = struct {
    fn write(runtime: spindle.io_adapter.IoRuntime, path: []const u8) !void {
        try runtime.writeFile(path, "real-file-data");
    }
};

test "io runtime asynchronously writes and reads a real temporary file" {
    const name = "spindle-task06-io-runtime.tmp";
    const runtime = spindle.io_adapter.IoRuntime.init(std.Options.debug_io);
    runtime.deleteFile(name) catch {};
    defer runtime.deleteFile(name) catch {};
    var future = runtime.async(FileIoProbe.write, .{ runtime, name });
    try future.await(runtime.io);
    var buffer: [32]u8 = undefined;
    const read = try runtime.readFile(name, &buffer);
    try std.testing.expectEqualStrings("real-file-data", read);
}

const PipelineProbe = struct {
    count: *std.atomic.Value(u32),
    sum: *std.atomic.Value(u32),
    fail_at: ?u32 = null,
    fn consume(self: *@This(), item: u32, _: spindle.executor.CancellationToken) !void {
        // Deliberately compute-bound: the bounded queue must absorb this slower stage.
        for (0..256) |_| std.atomic.spinLoopHint();
        _ = self.count.fetchAdd(1, .acq_rel);
        _ = self.sum.fetchAdd(item, .acq_rel);
        if (self.fail_at) |value| if (item == value) return error.ConsumerFailed;
    }
    fn dispose(_: u32) void {}
};

test "executor pipeline preserves items with a slow consumer and joins failure" {
    var pool = try spindle.executor.FixedPool.init(std.testing.allocator, 2, 32);
    defer pool.deinit();
    const input = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var count: std.atomic.Value(u32) = .init(0);
    var sum: std.atomic.Value(u32) = .init(0);
    var probe = PipelineProbe{ .count = &count, .sum = &sum };
    try spindle.parallel.pipeline.run(std.testing.allocator, pool.executor(), u32, &input, 2, &probe, PipelineProbe.consume, PipelineProbe.dispose);
    try std.testing.expectEqual(@as(u32, input.len), count.load(.acquire));
    try std.testing.expectEqual(@as(u32, 36), sum.load(.acquire));
    count.store(0, .release);
    sum.store(0, .release);
    probe.fail_at = 4;
    try std.testing.expectError(error.TaskFailed, spindle.parallel.pipeline.run(std.testing.allocator, pool.executor(), u32, &input, 2, &probe, PipelineProbe.consume, PipelineProbe.dispose));
    try std.testing.expect(count.load(.acquire) >= 1);
}

const BlockingBridgeProbe = struct {
    started: *spindle.sync.Semaphore,
    release: *spindle.sync.Event,
    completed: *std.atomic.Value(u32),
    fn run(task: *spindle.executor.Task) void {
        const self: *BlockingBridgeProbe = @ptrCast(@alignCast(task.context.?));
        self.started.release(1) catch return;
        self.release.wait(null, .{}) catch return;
        _ = self.completed.fetchAdd(1, .acq_rel);
    }
};

test "blocking bridge is bounded and does not consume compute workers" {
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 2);
    defer blocking.deinit();
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 2);
    defer compute.deinit();
    var bridge = spindle.io_adapter.BlockingBridge.init(&blocking);
    var started = try spindle.sync.Semaphore.init(0, 1);
    var release = spindle.sync.Event.init(.manual, false);
    var finished: std.atomic.Value(u32) = .init(0);
    var probe = BlockingBridgeProbe{ .started = &started, .release = &release, .completed = &finished };
    var first = spindle.executor.Task.init(BlockingBridgeProbe.run, &probe);
    var queued = spindle.executor.Task.init(BlockingBridgeProbe.run, &probe);
    var queued_second = spindle.executor.Task.init(BlockingBridgeProbe.run, &probe);
    var rejected = spindle.executor.Task.init(BlockingBridgeProbe.run, &probe);
    try bridge.submit(&first, null, null);
    try started.acquire(spindle.platform.park.deadlineAfter(std.time.ns_per_s), .{});
    try bridge.submit(&queued, null, null);
    try bridge.submit(&queued_second, null, null);
    try std.testing.expectError(error.Backpressure, bridge.submit(&rejected, null, null));
    var compute_probe = TaskProbe{ .value = &finished };
    var compute_task = spindle.executor.Task.init(TaskProbe.run, &compute_probe);
    try compute.submit(&compute_task, .{});
    try compute_task.wait();
    release.set();
    try first.wait();
    try queued.wait();
    try queued_second.wait();
    try std.testing.expect(finished.load(.acquire) >= 3);
}

const GraphProbe = struct {
    value: *std.atomic.Value(u32),
    fail: bool = false,
    fn run(context: *spindle.task_graph.TaskContext) void {
        const self: *GraphProbe = @ptrCast(@alignCast(context.user_context.?));
        _ = self.value.fetchAdd(1, .acq_rel);
        if (self.fail) context.fail();
    }
};

test "local task graph compiles a DAG and executes each dependency once" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var inline_executor: spindle.executor.InlineExecutor = .{};
    const target = try registry.register(inline_executor.executor());
    var value: std.atomic.Value(u32) = .init(0);
    var first_probe = GraphProbe{ .value = &value };
    var second_probe = GraphProbe{ .value = &value };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    const first = try builder.addTask(target, &first_probe, GraphProbe.run);
    const second = try builder.addTask(target, &second_probe, GraphProbe.run);
    try builder.dependsOn(second, first);
    var graph = try builder.compile(std.testing.allocator, &registry);
    defer graph.deinit();
    var handle = try spindle.task_graph.start(std.testing.allocator, &graph, null);
    defer handle.deinit();
    try handle.wait();
    try std.testing.expectEqual(@as(u32, 2), value.load(.acquire));
    const snapshot = handle.snapshot();
    try std.testing.expectEqual(@as(usize, 2), snapshot.completed);
    try std.testing.expectEqual(spindle.task_graph.LocalTaskState.completed, snapshot.states[0]);
    try std.testing.expectEqual(spindle.task_graph.LocalTaskState.completed, snapshot.states[1]);
}

test "local task graph rejects cycles before task execution" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var inline_executor: spindle.executor.InlineExecutor = .{};
    const target = try registry.register(inline_executor.executor());
    var value: std.atomic.Value(u32) = .init(0);
    var probe = GraphProbe{ .value = &value };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    const a = try builder.addTask(target, &probe, GraphProbe.run);
    const b = try builder.addTask(target, &probe, GraphProbe.run);
    try builder.dependsOn(a, b);
    try builder.dependsOn(b, a);
    try std.testing.expectError(error.CycleDetected, builder.compile(std.testing.allocator, &registry));
    try std.testing.expectEqual(@as(u32, 0), value.load(.acquire));
}

test "local task graph waits for caller-driven pump routing" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 4);
    defer pump.deinit();
    const target = try registry.register(pump.executor());
    var value: std.atomic.Value(u32) = .init(0);
    var probe = GraphProbe{ .value = &value };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addTask(target, &probe, GraphProbe.run);
    var graph = try builder.compile(std.testing.allocator, &registry);
    defer graph.deinit();
    var handle = try spindle.task_graph.start(std.testing.allocator, &graph, null);
    defer handle.deinit();
    try std.testing.expectEqual(@as(usize, 0), handle.snapshot().completed);
    try std.testing.expectEqual(@as(usize, 1), pump.drain(1));
    try handle.wait();
    try std.testing.expectEqual(@as(u32, 1), value.load(.acquire));
}

test "local task graph propagates failure and explicit cancellation" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var pump = try spindle.executor.PumpExecutor.init(std.testing.allocator, 4);
    defer pump.deinit();
    const target = try registry.register(pump.executor());
    var value: std.atomic.Value(u32) = .init(0);
    var failed_probe = GraphProbe{ .value = &value, .fail = true };
    var child_probe = GraphProbe{ .value = &value };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    const failed = try builder.addTask(target, &failed_probe, GraphProbe.run);
    const child = try builder.addTask(target, &child_probe, GraphProbe.run);
    try builder.dependsOn(child, failed);
    var graph = try builder.compile(std.testing.allocator, &registry);
    defer graph.deinit();
    var failed_handle = try spindle.task_graph.start(std.testing.allocator, &graph, null);
    defer failed_handle.deinit();
    _ = pump.drain(1);
    try std.testing.expectError(error.GraphFailed, failed_handle.wait());
    try std.testing.expectEqual(@as(u32, 1), value.load(.acquire));
    try std.testing.expectEqual(spindle.task_graph.LocalTaskState.cancelled, failed_handle.snapshot().states[1]);

    value.store(0, .release);
    var cancel_builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer cancel_builder.deinit();
    _ = try cancel_builder.addTask(target, &child_probe, GraphProbe.run);
    var cancel_graph = try cancel_builder.compile(std.testing.allocator, &registry);
    defer cancel_graph.deinit();
    var cancel_handle = try spindle.task_graph.start(std.testing.allocator, &cancel_graph, null);
    defer cancel_handle.deinit();
    cancel_handle.cancel();
    _ = pump.drain(1);
    try std.testing.expectError(error.Cancelled, cancel_handle.wait());
    try std.testing.expectEqual(@as(u32, 0), value.load(.acquire));
}

test "local task graph emits matched started terminal trace events" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var inline_executor: spindle.executor.InlineExecutor = .{};
    const target = try registry.register(inline_executor.executor());
    var value: std.atomic.Value(u32) = .init(0);
    var probe = GraphProbe{ .value = &value };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    _ = try builder.addTask(target, &probe, GraphProbe.run);
    var graph = try builder.compile(std.testing.allocator, &registry);
    defer graph.deinit();
    var events: [8]spindle.observability.event.Event = undefined;
    var ring = spindle.observability.event.RingSink.init(&events);
    var handle = try spindle.task_graph.start(std.testing.allocator, &graph, ring.sink());
    defer handle.deinit();
    try handle.wait();
    var started: usize = 0;
    var terminal: usize = 0;
    while (ring.pop()) |event| {
        if (std.mem.eql(u8, event.kind, "task_graph.started")) started += 1;
        if (std.mem.eql(u8, event.kind, "task_graph.finished") or std.mem.eql(u8, event.kind, "task_graph.cancelled")) terminal += 1;
    }
    try std.testing.expectEqual(started, terminal);
    try std.testing.expectEqual(@as(usize, 1), started);
}

test "compiled local task graph has independent concurrent execution state" {
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var pool = try spindle.executor.FixedPool.init(std.testing.allocator, 2, 16);
    defer pool.deinit();
    const target = try registry.register(pool.executor());
    var value: std.atomic.Value(u32) = .init(0);
    var probes: [3]GraphProbe = undefined;
    for (&probes) |*probe| probe.* = .{ .value = &value };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    const left = try builder.addTask(target, &probes[0], GraphProbe.run);
    const right = try builder.addTask(target, &probes[1], GraphProbe.run);
    const join = try builder.addTask(target, &probes[2], GraphProbe.run);
    try builder.dependsOn(join, left);
    try builder.dependsOn(join, right);
    var graph = try builder.compile(std.testing.allocator, &registry);
    defer graph.deinit();
    var first = try spindle.task_graph.start(std.testing.allocator, &graph, null);
    defer first.deinit();
    var second = try spindle.task_graph.start(std.testing.allocator, &graph, null);
    defer second.deinit();
    try first.wait();
    try second.wait();
    try std.testing.expectEqual(@as(u32, 6), value.load(.acquire));
}

const EcsPosition = struct { x: i32 };
const EcsVelocity = struct { x: i32 };

test "ecs query plans refresh incrementally and enforce declared writes" {
    var world = try spindle.ecs.World.init(std.testing.allocator, .{});
    defer world.deinit();
    const position = try world.registerComponent(EcsPosition, "test.query.position");
    const velocity = try world.registerComponent(EcsVelocity, "test.query.velocity");
    const first = try world.create();
    try world.add(first, position, EcsPosition{ .x = 2 });
    var plan = try spindle.ecs.QueryPlan.init(std.testing.allocator, &world, .{ .required = &.{position}, .write = &.{position} });
    defer plan.deinit();
    var iterator = try plan.iterator(&world);
    var view = iterator.next().?;
    const positions = try view.write(position, EcsPosition);
    positions[0].x = 7;
    try std.testing.expectError(error.UndeclaredWrite, view.write(velocity, EcsVelocity));
    try std.testing.expectError(error.ActiveChunkBorrow, world.create());
    view.deinit();
    const second = try world.create();
    try world.add(second, position, EcsPosition{ .x = 4 });
    try world.add(second, velocity, EcsVelocity{ .x = 9 });
    iterator = try plan.iterator(&world);
    var count: usize = 0;
    while (iterator.next()) |value| {
        var chunk = value;
        count += chunk.entities().len;
        chunk.deinit();
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "ecs deferred commands resolve temporary entities and merge deterministically" {
    var world = try spindle.ecs.World.init(std.testing.allocator, .{});
    defer world.deinit();
    const position = try world.registerComponent(EcsPosition, "test.command.position");
    var queue = spindle.ecs.CommandQueue.init(std.testing.allocator);
    var first = queue.buffer();
    defer first.deinit();
    const temp = try first.create();
    try first.add(temp, position, EcsPosition{ .x = 1 });
    try first.set(temp, position, EcsPosition{ .x = 5 });
    var buffers = [_]@TypeOf(first){first};
    try queue.apply(&world, &buffers);
    try std.testing.expectEqual(@as(usize, 1), world.entities.slots.items.len);
    const entity = world.archetypes.items[1].chunks.items[0].entities()[0];
    try std.testing.expectEqual(@as(i32, 5), (try world.get(entity, position, EcsPosition)).x);
}

test "ecs deferred destroy has deterministic batch precedence" {
    var world = try spindle.ecs.World.init(std.testing.allocator, .{});
    defer world.deinit();
    const position = try world.registerComponent(EcsPosition, "test.command.destroy-position");
    const value = try world.create();
    try world.add(value, position, EcsPosition{ .x = 1 });
    var queue = spindle.ecs.CommandQueue.init(std.testing.allocator);
    var buffer = queue.buffer();
    defer buffer.deinit();
    try buffer.set(.{ .entity = value }, position, EcsPosition{ .x = 9 });
    try buffer.destroy(.{ .entity = value });
    try buffer.add(.{ .entity = value }, position, EcsPosition{ .x = 17 });
    var buffers = [_]@TypeOf(buffer){buffer};
    try queue.apply(&world, &buffers);
    try std.testing.expect(!world.isAlive(value));
}

test "ecs command preflight OOM leaves the world unchanged" {
    var world = try spindle.ecs.World.init(std.testing.allocator, .{});
    defer world.deinit();
    const position = try world.registerComponent(EcsPosition, "test.command.preflight-oom-position");
    const value = try world.create();
    try world.add(value, position, EcsPosition{ .x = 3 });
    var queue = spindle.ecs.CommandQueue.init(std.testing.allocator);
    var buffer = queue.buffer();
    defer buffer.deinit();
    try buffer.add(.{ .entity = value }, position, EcsPosition{ .x = 12 });
    var buffers = [_]@TypeOf(buffer){buffer};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    world.allocator = failing.allocator();
    world.entities.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, queue.apply(&world, &buffers));
    world.allocator = std.testing.allocator;
    world.entities.allocator = std.testing.allocator;
    try std.testing.expect(world.isAlive(value));
    try std.testing.expectEqual(@as(i32, 3), (try world.get(value, position, EcsPosition)).x);
}

test "ecs frame events merge by global sequence and expire at frame advance" {
    var events = spindle.ecs.event.FrameEvent(u32).init(std.testing.allocator);
    defer events.deinit();
    var left = events.buffer();
    defer left.deinit();
    var right = events.buffer();
    defer right.deinit();
    try left.emit(1);
    try right.emit(2);
    var buffers = [_]@TypeOf(left){ left, right };
    try events.merge(&buffers);
    try std.testing.expectEqualSlices(u32, &.{ 1, 2 }, events.events());
    events.advance();
    try std.testing.expectEqual(@as(usize, 0), events.events().len);
}
