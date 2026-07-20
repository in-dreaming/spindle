const std = @import("std");
const builtin = @import("builtin");
const spindle = @import("spindle");

const Probe = struct {
    completed: *std.atomic.Value(u32),
    latencies: []u64,
    cursor: *std.atomic.Value(usize),
    work_ns: u64,
    fn run(task: *spindle.executor.Task) void {
        const self: *Probe = @ptrCast(@alignCast(task.context.?));
        const started = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
        while (true) {
            const now = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
            const elapsed: u64 = @intCast(now.raw.nanoseconds - started.raw.nanoseconds);
            if (elapsed >= self.work_ns) {
                const index = self.cursor.fetchAdd(1, .acq_rel);
                self.latencies[index] = elapsed;
                break;
            }
            std.atomic.spinLoopHint();
        }
        _ = self.completed.fetchAdd(1, .release);
    }
};

pub fn main() void {
    const allocator = std.heap.page_allocator;
    runWorkload(allocator, 10_000);
    runParallelFor(allocator);
    if (comptime spindle.runtime.Features.ecs) runEcsScheduler(allocator);
}

const ParallelBench = struct {
    total: *std.atomic.Value(usize),
    fn run(self: *@This(), begin: usize, end: usize, _: spindle.executor.CancellationToken) !void {
        _ = self.total.fetchAdd(end - begin, .acq_rel);
    }
};

fn runParallelFor(allocator: std.mem.Allocator) void {
    var pool = spindle.executor.FixedPool.init(allocator, 2, 64) catch return;
    defer pool.deinit();
    var total: std.atomic.Value(usize) = .init(0);
    var probe = ParallelBench{ .total = &total };
    const started = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
    spindle.parallel.forRange(allocator, pool.executor(), .{ .end = 65_536 }, .{ .grain = 1024 }, &probe, ParallelBench.run) catch return;
    const elapsed: u64 = @intCast(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds - started.raw.nanoseconds);
    std.debug.print("{{\"schema_version\":1,\"benchmark\":\"parallel_for\",\"grain\":1024,\"items\":{d},\"elapsed_ns\":{d},\"os\":\"{s}\",\"workers\":2}}\n", .{ total.load(.acquire), elapsed, @tagName(builtin.os.tag) });
}

fn runWorkload(allocator: std.mem.Allocator, work_ns: u64) void {
    var executor = spindle.executor.FixedPool.init(allocator, 2, 2048) catch return;
    defer executor.deinit();
    const count: usize = 512;
    const tasks = allocator.alloc(spindle.executor.Task, count) catch return;
    defer allocator.free(tasks);
    const latencies = allocator.alloc(u64, count) catch return;
    defer allocator.free(latencies);
    var completed: std.atomic.Value(u32) = .init(0);
    var cursor: std.atomic.Value(usize) = .init(0);
    var probe = Probe{ .completed = &completed, .latencies = latencies, .cursor = &cursor, .work_ns = work_ns };
    const started = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
    for (tasks) |*task| {
        task.* = spindle.executor.Task.init(Probe.run, &probe);
        executor.submit(task, .{}) catch return;
    }
    for (tasks) |*task| task.wait() catch return;
    const elapsed: u64 = @intCast(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds - started.raw.nanoseconds);
    std.sort.pdq(u64, latencies, {}, std.sort.asc(u64));
    const throughput = @as(u64, @intCast(count)) * std.time.ns_per_s / @max(@as(u64, 1), elapsed);
    std.debug.print("{{\"schema_version\":1,\"benchmark\":\"fixed_pool\",\"work_ns\":{d},\"samples\":{d},\"throughput\":{d},\"latency_ns\":{d},\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d},\"os\":\"{s}\",\"workers\":2}}\n", .{ work_ns, count, throughput, elapsed / @as(u64, @intCast(count)), percentile(latencies, 50), percentile(latencies, 95), percentile(latencies, 99), @tagName(builtin.os.tag) });
}

const EcsPosition = struct { value: u32 };
const EcsProbe = struct { ranges: std.atomic.Value(u64) = .init(0) };
fn ecsIncrement(context: *spindle.ecs.SystemContext, maybe_view: ?*spindle.ecs.query.ChunkView) anyerror!void {
    const probe = try context.resource(1, EcsProbe);
    const view = maybe_view orelse return;
    const values = try view.write(context.desc.query.write[0], EcsPosition);
    for (values) |*value| value.value += 1;
    _ = probe.ranges.fetchAdd(1, .monotonic);
}
fn runEcsScheduler(allocator: std.mem.Allocator) void {
    var world = spindle.ecs.World.init(allocator, .{ .chunk_bytes = 16 * 1024 }) catch return;
    defer world.deinit();
    const position = world.registerComponent(EcsPosition, "bench.ecs.position") catch return;
    var probe = EcsProbe{};
    world.registerResource(1, @ptrCast(&probe)) catch return;
    var created: usize = 0;
    while (created < 16_384) : (created += 1) {
        const value = world.create() catch return;
        world.add(value, position, EcsPosition{ .value = 0 }) catch return;
    }
    world.registerSystem(.{ .id = 1, .name = "bench_increment", .component_writes = &.{position}, .resource_writes = &.{1}, .query = .{ .required = &.{position}, .write = &.{position} }, .grain = 256, .run_fn = ecsIncrement }) catch return;
    var pool = spindle.executor.FixedPool.init(allocator, 2, 256) catch return;
    defer pool.deinit();
    const started = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake);
    world.update(.{ .compute = pool.executor() }, 1.0) catch return;
    const elapsed: u64 = @intCast(std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds - started.raw.nanoseconds);
    const throughput = @as(u64, 16_384) * std.time.ns_per_s / @max(@as(u64, 1), elapsed);
    std.debug.print("{{\"schema_version\":1,\"benchmark\":\"ecs_scheduler\",\"entities\":16384,\"chunk_range_jobs\":{d},\"throughput\":{d},\"elapsed_ns\":{d},\"os\":\"{s}\",\"workers\":2}}\n", .{ probe.ranges.load(.acquire), throughput, elapsed, @tagName(builtin.os.tag) });
}

fn percentile(values: []const u64, percent: usize) u64 {
    return values[@min(values.len - 1, values.len * percent / 100)];
}
