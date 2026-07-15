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

const ShutdownRaceProbe = struct {
    ran: *std.atomic.Value(u32),
    fn run(task: *spindle.executor.Task) void {
        const self: *ShutdownRaceProbe = @ptrCast(@alignCast(task.context.?));
        _ = self.ran.fetchAdd(1, .acq_rel);
    }
};

const ShutdownSubmitter = struct {
    executor: *spindle.executor.WorkStealingExecutor,
    tasks: []spindle.executor.Task,
    started: *spindle.sync.Semaphore,
    seed: u64,
    fn run(self: @This()) void {
        self.started.release(1) catch return;
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();
        for (self.tasks) |*task| {
            _ = self.executor.submit(task, .{}) catch {};
            for (0..random.uintLessThan(u8, 3)) |_| std.atomic.spinLoopHint();
        }
    }
};

const ShutdownRaceRun = struct {
    allocator: std.mem.Allocator,
    iterations: u32,
    seed: u64,
    done: *spindle.sync.Event,
    result: *std.atomic.Value(bool),
    fn run(self: @This()) void {
        defer self.done.set();
        var prng = std.Random.DefaultPrng.init(self.seed);
        const random = prng.random();
        for (0..self.iterations) |iteration| {
            var executor = spindle.executor.WorkStealingExecutor.init(self.allocator, .{ .workers = 2, .local_capacity = 8, .injection_capacity = 32, .urgent_capacity = 4 }) catch return;
            defer executor.deinit();
            var ran: std.atomic.Value(u32) = .init(0);
            var probe = ShutdownRaceProbe{ .ran = &ran };
            var tasks: [48]spindle.executor.Task = undefined;
            for (&tasks) |*task| task.* = spindle.executor.Task.init(ShutdownRaceProbe.run, &probe);
            var started = spindle.sync.Semaphore.init(0, 1) catch return;
            const submitter = spindle.platform.thread.spawn(.{}, ShutdownSubmitter.run, .{ShutdownSubmitter{ .executor = &executor, .tasks = &tasks, .started = &started, .seed = random.int(u64) }}) catch return;
            started.acquire(spindle.platform.park.deadlineAfter(std.time.ns_per_s), .{}) catch return;
            if (iteration % 2 == 0) std.Thread.yield() catch {};
            executor.shutdown(.cancel_pending);
            submitter.join();
            for (&tasks) |*task| {
                if (task.queue_references.load(.acquire) != 0) return;
                switch (task.status()) {
                    .created, .completed, .cancelled => {},
                    else => return,
                }
            }
        }
        self.result.store(true, .release);
    }
};

test "work-stealing submit shutdown race is bounded and releases every queue reference" {
    const seed: u64 = 0x5a17_05e5_d00d_cafe;
    var done = spindle.sync.Event.init(.manual, false);
    var passed: std.atomic.Value(bool) = .init(false);
    const runner = try spindle.platform.thread.spawn(.{}, ShutdownRaceRun.run, .{ShutdownRaceRun{ .allocator = std.testing.allocator, .iterations = @min(build_options.iterations, 64), .seed = seed, .done = &done, .result = &passed }});
    try done.wait(spindle.platform.park.deadlineAfter(5 * std.time.ns_per_s), .{});
    runner.join();
    try std.testing.expect(passed.load(.acquire));
}

const GraphStressProbe = struct {
    count: *std.atomic.Value(u32),
    fn run(context: *spindle.task_graph.TaskContext) void {
        const self: *GraphStressProbe = @ptrCast(@alignCast(context.user_context.?));
        _ = self.count.fetchAdd(1, .acq_rel);
    }
};

test "local task graph high fan-in releases its join exactly once" {
    const fan_in = 32;
    const iterations = @min(build_options.iterations, 16);
    var executor = try spindle.executor.FixedPool.init(std.testing.allocator, 4, 128);
    defer executor.deinit();
    var registry = spindle.executor.ExecutorRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const target = try registry.register(executor.executor());
    var count: std.atomic.Value(u32) = .init(0);
    var probes: [fan_in + 1]GraphStressProbe = undefined;
    for (&probes) |*probe| probe.* = .{ .count = &count };
    var builder = spindle.task_graph.LocalTaskGraph.init(std.testing.allocator);
    defer builder.deinit();
    var inputs: [fan_in]spindle.task_graph.NodeId = undefined;
    for (&inputs, 0..) |*id, i| id.* = try builder.addTask(target, &probes[i], GraphStressProbe.run);
    const join = try builder.addTask(target, &probes[fan_in], GraphStressProbe.run);
    for (inputs) |input| try builder.dependsOn(join, input);
    var graph = try builder.compile(std.testing.allocator, &registry);
    defer graph.deinit();
    for (0..iterations) |_| {
        var handle = try spindle.task_graph.start(std.testing.allocator, &graph, null);
        try handle.wait();
        const snapshot = handle.snapshot();
        try std.testing.expectEqual(snapshot.total, snapshot.completed);
        try std.testing.expectEqual(spindle.task_graph.LocalTaskState.completed, snapshot.states[fan_in]);
        handle.deinit();
    }
    try std.testing.expectEqual(@as(u32, fan_in + 1) * iterations, count.load(.acquire));
}
