const std = @import("std");
const executor = @import("../executor/root.zig");
const MpmcQueue = @import("../concurrent/mpmc_queue.zig").MpmcQueue;

/// A bounded synchronous stage connection. Producers receive `Backpressure`
/// when capacity is reached; callers own items and must drain after cancellation.
pub fn Bounded(comptime T: type) type {
    return struct {
        const Self = @This();
        buffer: []T,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        pub fn init(buffer: []T) Self {
            return .{ .buffer = buffer };
        }
        pub fn push(self: *Self, value: T) !void {
            if (self.closed) return error.Closed;
            if (self.len == self.buffer.len) return error.Backpressure;
            self.buffer[(self.head + self.len) % self.buffer.len] = value;
            self.len += 1;
        }
        pub fn pop(self: *Self) !T {
            if (self.len == 0) return if (self.closed) error.Closed else error.Empty;
            const value = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.len -= 1;
            return value;
        }
        pub fn close(self: *Self) void {
            self.closed = true;
        }
    };
}

/// Runs a producer/consumer pipeline on `target`. The queue capacity is fixed
/// and must be a power of two. `consume` failures cancel the scope; `dispose`
/// receives every item left in the queue after cancellation or failure.
pub fn run(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, input: []const T, queue_capacity: usize, context: anytype, consume: anytype, dispose: anytype) !void {
    if (target.workerCount() <= 1) {
        var source: executor.CancellationSource = .{};
        for (input) |item| try @call(.auto, consume, .{ context, item, source.token() });
        return;
    }
    var queue = try MpmcQueue(T).init(allocator, queue_capacity);
    defer queue.deinit(dispose);
    const State = struct {
        queue: *MpmcQueue(T),
        input: []const T,
        context: @TypeOf(context),
        scope: *executor.Scope,
        fn producer(task: *executor.Task) void {
            const state: *@This() = @ptrCast(@alignCast(task.context.?));
            defer state.queue.close();
            for (state.input) |item| {
                while (true) {
                    if (state.scope.cancellation.token().isCancelled()) return;
                    state.queue.tryPush(item) catch |err| switch (err) {
                        error.Full => {
                            std.Thread.yield() catch {};
                            continue;
                        },
                        error.Closed => return,
                    };
                    break;
                }
            }
        }
        fn consumer(task: *executor.Task) void {
            const state: *@This() = @ptrCast(@alignCast(task.context.?));
            while (true) {
                if (state.scope.cancellation.token().isCancelled()) return;
                const item = state.queue.tryPop() catch |err| switch (err) {
                    error.Empty => {
                        std.Thread.yield() catch {};
                        continue;
                    },
                    error.Closed => return,
                };
                @call(.auto, consume, .{ state.context, item, state.scope.cancellation.token() }) catch {
                    task.fail();
                    return;
                };
            }
        }
    };
    var scope = executor.Scope.init(target, .cancel_on_first_error);
    var state = State{ .queue = &queue, .input = input, .context = context, .scope = &scope };
    var producer_task = executor.Task.init(State.producer, &state);
    var consumer_task = executor.Task.init(State.consumer, &state);
    try scope.spawn(&producer_task);
    try scope.spawn(&consumer_task);
    try scope.wait();
}
