const std = @import("std");
const FixedPool = @import("fixed_pool.zig").FixedPool;
const Task = @import("task.zig").Task;
const api = @import("executor.zig");

/// Single-worker FIFO executor. It always owns exactly one worker and preserves acceptance order.
pub const SerialExecutor = struct {
    pool: FixedPool,
    pub fn init(allocator: std.mem.Allocator, queue_capacity: usize) !SerialExecutor {
        return .{ .pool = try FixedPool.init(allocator, 1, queue_capacity) };
    }
    pub fn deinit(self: *SerialExecutor) void {
        self.pool.deinit();
    }
    pub fn executor(self: *SerialExecutor) api.Executor {
        return self.pool.executor();
    }
    pub fn submit(self: *SerialExecutor, task: *Task, options: api.SubmitOptions) api.SubmitError!void {
        try self.pool.submit(task, options);
    }
    pub fn shutdown(self: *SerialExecutor, policy: api.ShutdownPolicy) void {
        self.pool.shutdown(policy);
    }
};
