const std = @import("std");
const FixedPool = @import("fixed_pool.zig").FixedPool;
const Task = @import("task.zig").Task;
const api = @import("executor.zig");
const park = @import("../platform/park.zig");

/// Dedicated bounded pool for blocking calls. It is intentionally distinct from compute pools.
pub const BlockingExecutor = struct {
    pool: FixedPool,
    pub fn init(allocator: std.mem.Allocator, workers: usize, queue_capacity: usize) !BlockingExecutor {
        return .{ .pool = try FixedPool.init(allocator, workers, queue_capacity) };
    }
    pub fn deinit(self: *BlockingExecutor) void {
        self.pool.deinit();
    }
    pub fn executor(self: *BlockingExecutor) api.Executor {
        return self.pool.executor();
    }
    pub fn submit(self: *BlockingExecutor, task: *Task, options: api.SubmitOptions) api.SubmitError!void {
        try self.pool.submit(task, options);
    }
    pub fn shutdown(self: *BlockingExecutor, policy: api.ShutdownPolicy) void {
        self.pool.shutdown(policy);
    }
    pub fn requestStop(self: *BlockingExecutor, policy: api.ShutdownPolicy) void {
        self.pool.requestStop(policy);
    }
    pub fn wait(self: *BlockingExecutor, deadline: ?park.Deadline) error{Timeout}!void {
        try self.pool.wait(deadline);
    }
    pub fn outstandingWorkers(self: *const BlockingExecutor) usize {
        return self.pool.outstandingWorkers();
    }
};
