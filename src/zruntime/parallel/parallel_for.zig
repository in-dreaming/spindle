const std = @import("std");
const executor = @import("../executor/root.zig");

pub const Range = struct { start: usize = 0, end: usize };
pub const Options = struct { grain: ?usize = null, dynamic: bool = false };

/// Computes the static chunk geometry used by the parallel algorithms.
pub fn chunkGeometry(target: executor.Executor, length: usize, requested_grain: ?usize) struct { grain: usize, chunks: usize } {
    if (length == 0) return .{ .grain = 1, .chunks = 0 };
    const workers = @max(@as(usize, 1), target.workerCount());
    const grain = requested_grain orelse @max(@as(usize, 1), (length + workers * 8 - 1) / (workers * 8));
    return .{ .grain = grain, .chunks = (length + grain - 1) / grain };
}

/// Runs bounded chunks over `[range.start, range.end)`. `body` may return an
/// error; the first failing chunk cancels its scope and all chunks are joined.
pub fn forRange(allocator: std.mem.Allocator, target: executor.Executor, range: Range, options: Options, context: anytype, body: anytype) !void {
    if (range.end < range.start) return error.InvalidRange;
    const count = range.end - range.start;
    if (count == 0) return;
    const geometry = chunkGeometry(target, count, options.grain);
    const workers = @max(@as(usize, 1), target.workerCount());
    const grain = geometry.grain;
    if (grain == 0) return error.InvalidGrain;
    const chunks = geometry.chunks;
    const Context = @TypeOf(context);
    const State = struct {
        context: Context,
        scope: *executor.Scope,
        next: std.atomic.Value(usize),
        range: Range,
        grain_size: usize,
        fn run(task: *executor.Task) void {
            const state: *@This() = @ptrCast(@alignCast(task.context.?));
            while (true) {
                const begin = state.next.fetchAdd(state.grain_size, .acq_rel);
                if (begin >= state.range.end) return;
                const end = @min(state.range.end, begin + state.grain_size);
                if (state.scope.cancellation.token().isCancelled()) return;
                @call(.auto, body, .{ state.context, begin, end, state.scope.cancellation.token() }) catch {
                    task.fail();
                    return;
                };
            }
        }
    };
    var scope = executor.Scope.init(target, .cancel_on_first_error);
    var state = State{ .context = context, .scope = &scope, .next = .init(range.start), .range = range, .grain_size = grain };
    const task_count = if (options.dynamic) @min(chunks, workers * 8) else chunks;
    const tasks = try allocator.alloc(executor.Task, task_count);
    defer allocator.free(tasks);
    for (tasks) |*task| {
        task.* = executor.Task.init(State.run, &state);
        try scope.spawn(task);
    }
    const scope_result = scope.wait();
    // Scope completion runs before a worker releases its intrusive queue
    // reference. `tasks` is caller-owned, so retain it until all workers have
    // released those references, including after cancellation.
    for (tasks) |*task| try task.waitQueueReleased();
    try scope_result;
}

/// Applies `body(context, item, index, token)` over a slice using `forRange`.
pub fn forEach(allocator: std.mem.Allocator, target: executor.Executor, items: anytype, options: Options, context: anytype, body: anytype) !void {
    const State = struct { items: @TypeOf(items), context: @TypeOf(context) };
    var state = State{ .items = items, .context = context };
    try forRange(allocator, target, .{ .end = items.len }, options, &state, struct {
        fn run(s: *State, begin: usize, end: usize, token: executor.CancellationToken) !void {
            for (begin..end) |index| try @call(.auto, body, .{ s.context, s.items[index], index, token });
        }
    }.run);
}

/// Invokes up to `workers * 8` independent functions and joins them in a scope.
pub fn invoke(allocator: std.mem.Allocator, target: executor.Executor, functions: anytype) !void {
    const State = struct { functions: @TypeOf(functions) };
    var state = State{ .functions = functions };
    try forRange(allocator, target, .{ .end = functions.len }, .{ .grain = 1 }, &state, struct {
        fn run(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            for (begin..end) |index| try @call(.auto, s.functions[index], .{});
        }
    }.run);
}
