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
    const work_ns = [_]u64{ 0, 1_000, 10_000, 100_000, 1_000_000 };
    for (work_ns) |duration| runWorkload(allocator, duration);
    runParallelFor(allocator);
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
    std.debug.print("{{\"benchmark\":\"parallel_for\",\"grain\":1024,\"items\":{d},\"elapsed_ns\":{d},\"os\":\"{s}\",\"workers\":2}}\n", .{ total.load(.acquire), elapsed, @tagName(builtin.os.tag) });
}

fn runWorkload(allocator: std.mem.Allocator, work_ns: u64) void {
    var executor = spindle.executor.WorkStealingExecutor.init(allocator, .{ .workers = 2, .local_capacity = 256, .injection_capacity = 2048, .urgent_capacity = 64 }) catch return;
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
    std.debug.print("{{\"benchmark\":\"work_stealing\",\"work_ns\":{d},\"samples\":{d},\"throughput\":{d},\"latency_ns\":{d},\"p50_ns\":{d},\"p95_ns\":{d},\"p99_ns\":{d},\"os\":\"{s}\",\"workers\":2}}\n", .{ work_ns, count, throughput, elapsed / @as(u64, @intCast(count)), percentile(latencies, 50), percentile(latencies, 95), percentile(latencies, 99), @tagName(builtin.os.tag) });
}

fn percentile(values: []const u64, percent: usize) u64 {
    return values[@min(values.len - 1, values.len * percent / 100)];
}
