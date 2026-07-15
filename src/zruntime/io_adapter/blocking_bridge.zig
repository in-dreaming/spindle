const executor = @import("../executor/root.zig");
const park = @import("../platform/park.zig");

/// Routes caller-owned blocking tasks exclusively through a BlockingExecutor.
/// Submission is bounded by the executor queue and returns `Backpressure`.
pub const BlockingBridge = struct {
    blocking: *executor.BlockingExecutor,
    pub fn init(blocking: *executor.BlockingExecutor) BlockingBridge {
        return .{ .blocking = blocking };
    }
    pub fn submit(self: *BlockingBridge, task: *executor.Task, deadline: ?park.Deadline, token: ?executor.CancellationToken) !void {
        if (token) |value| if (value.isCancelled()) return error.Cancelled;
        if (park.expired(deadline)) return error.Timeout;
        try self.blocking.submit(task, .{});
    }
};
