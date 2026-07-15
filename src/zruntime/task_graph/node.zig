const executor = @import("../executor/root.zig");

/// Identifier of a node in a local graph. IDs are stable only within their graph.
pub const NodeId = packed struct(u32) {
    value: u32,
    pub const invalid = NodeId{ .value = 0 };
    pub fn isValid(self: NodeId) bool {
        return self.value != 0;
    }
};

/// Per-execution node state returned by execution snapshots.
pub const LocalTaskState = enum(u8) { pending, queued, running, completed, failed, cancelled };

/// Callback context. Callbacks must poll cancellation when they perform lengthy work.
pub const TaskContext = struct {
    user_context: ?*anyopaque,
    cancellation: executor.CancellationToken,
    failed: bool = false,

    pub fn fail(self: *TaskContext) void {
        self.failed = true;
    }
    pub fn isCancelled(self: *const TaskContext) bool {
        return self.cancellation.isCancelled();
    }
};

/// A graph node callback. It is invoked at most once for each execution.
pub const TaskFn = *const fn (*TaskContext) void;
