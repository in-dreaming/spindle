const core = @import("../core/root.zig");
const event = @import("event.zig");
const instance = @import("instance.zig");
const snapshot = @import("snapshot.zig");

/// Transactional history event. Payload memory is borrowed for the duration of the call.
pub const HistoryAppend = struct { event_id: core.StableId, value: event.Event };
/// A ready workflow task created in the same transaction as its predecessor's completion.
pub const WorkflowTask = struct { task_id: core.StableId };
/// At-least-once activity delivery derived from a deterministic command.
pub const ActivityTask = struct { task_id: core.StableId, command_sequence: u64, schema: core.schema.SchemaKey, payload: []const u8 };
/// Durable timer. PostgreSQL server time is authoritative when it is later claimed.
pub const Timer = struct { timer_id: core.StableId, fire_at_utc_ms: i64, schema: core.schema.SchemaKey, payload: []const u8 };
/// An outbox message which remains publishable until a publisher marks it sent.
pub const OutboxMessage = struct { message_id: core.StableId, payload: []const u8 };
/// An independent child instance created with its parent transition.
pub const ChildStart = struct { workflow_id: core.StableId, task_id: core.StableId, event_id: core.StableId, definition_id: u64, definition_version: u32, schema: core.schema.SchemaKey, payload: []const u8, parent_close_policy: u8 };
/// A child cancellation requested by its parent's deterministic transition.
pub const ChildCancel = struct { workflow_id: core.StableId, event_id: core.StableId };
/// A compensation activity persisted as a plan step and delivered at least once.
pub const Compensation = struct { plan_id: core.StableId, task_id: core.StableId, command_sequence: u64, activity_type: u64, schema: core.schema.SchemaKey, payload: []const u8, input_hash: u64, index: u32 };
/// Work produced by a deterministic transition. Every item is persisted with the history commit.
pub const ScheduledWork = struct { next_task: ?WorkflowTask = null, activities: []const ActivityTask = &.{}, timers: []const Timer = &.{}, outbox: []const OutboxMessage = &.{}, children: []const ChildStart = &.{}, child_cancellations: []const ChildCancel = &.{}, compensations: []const Compensation = &.{} };
/// The complete single-transaction input for a workflow task transition.
pub const CommitInput = struct {
    tenant: []const u8,
    namespace: []const u8,
    workflow_id: core.StableId,
    task_id: core.StableId,
    expected_state_version: u64,
    lease_epoch: u64,
    new_state: []const u8,
    new_status: instance.Status,
    events: []const HistoryAppend,
    optional_snapshot: ?snapshot.Snapshot = null,
    scheduled: ScheduledWork = .{},
};
pub const Error = error{ Conflict, LeaseLost, DuplicateEventConflict, SequenceGap, PayloadTooLarge, DatabaseUnavailable, DatabaseFailure };
/// Storage contract. Implementations must atomically fence the lease, append history, and publish all derived work.
pub const Store = struct {
    context: *anyopaque,
    commit_fn: *const fn (*anyopaque, CommitInput) Error!void,
    pub fn commitWorkflowTaskTransition(self: Store, input: CommitInput) Error!void {
        return self.commit_fn(self.context, input);
    }
};
