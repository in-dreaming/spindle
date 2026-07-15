const std = @import("std");
const command = @import("command.zig");
const definition = @import("definition.zig");
const event = @import("event.zig");
const instance = @import("instance.zig");
const persistence = @import("persistence.zig");
const snapshot = @import("snapshot.zig");
const child = @import("child.zig");
const core = @import("../core/root.zig");

pub const checkpoint_interval: u64 = 64;
pub const Error = error{ UnsupportedCommand, CommandCapacityExceeded, CommandSequenceOverflow, NonDecisionEvent, DefinitionUnavailable };
pub const TransitionResult = struct {
    state: []const u8,
    status: instance.Status,
    last_decision_sequence: u64,
    commands: []const command.Command,
    optional_snapshot: ?snapshot.Snapshot,
};

/// Runs every newly visible decision in sequence on the calling worker thread. `last_processed_sequence`
/// is the durable decision fence, not necessarily the latest snapshot sequence. The returned state and
/// command payloads alias definition/history memory and must be committed before those buffers are released.
pub fn processDecisions(def: definition.Definition, workflow_id: @import("../core/stable_id.zig").StableId, initial_state: []const u8, last_processed_sequence: u64, decisions: []const event.Event, command_storage: []command.Command) (Error || anyerror)!TransitionResult {
    var state = initial_state;
    var status: instance.Status = .running;
    var expected = last_processed_sequence + 1;
    var output = command.Buffer.init(command_storage);
    for (decisions) |decision| {
        if (decision.sequence != expected) return error.InvalidSequence;
        expected += 1;
        if (isMetadataEvent(decision.kind)) continue;
        if (!isDecisionEvent(decision.kind)) return error.NonDecisionEvent;
        var context = definition.WorkflowContext{ .logical_utc_ms = decision.utc_ms, .random_values = &.{}, .commands = &output };
        const result = try def.transition(&context, state, decision);
        state = result.new_state;
        status = result.status;
    }
    const last = if (decisions.len == 0) last_processed_sequence else decisions[decisions.len - 1].sequence;
    return .{ .state = state, .status = status, .last_decision_sequence = last, .commands = output.slice(), .optional_snapshot = if (needsCheckpointForState(last_processed_sequence, last, status, state)) makeSnapshot(workflow_id, last, def.version, state) else null };
}

/// Returns whether a successful transition must atomically publish a replay checkpoint.
pub fn needsCheckpoint(previous_snapshot_sequence: u64, processed_sequence: u64, status: instance.Status) bool {
    return processed_sequence >= previous_snapshot_sequence + checkpoint_interval or status != .running;
}

/// Extends the interval/terminal policy with the durable waiting and compensating checkpoints.
pub fn needsCheckpointForState(previous_snapshot_sequence: u64, processed_sequence: u64, status: instance.Status, state: []const u8) bool {
    return needsCheckpoint(previous_snapshot_sequence, processed_sequence, status) or
        std.mem.eql(u8, state, "waiting") or std.mem.eql(u8, state, "compensating");
}

/// Returns true only for history records that drive a deterministic workflow transition.
pub fn isDecisionEvent(kind: u32) bool {
    return switch (kind) {
        event.Kind.started, event.Kind.signal_received, event.Kind.activity_completed, event.Kind.activity_failed, event.Kind.timer_fired, event.Kind.cancellation_requested, event.Kind.child_completed, event.Kind.child_failed, event.Kind.child_cancelled => true,
        else => false,
    };
}

/// Metadata facts are persisted for diagnosis and replay validation but do not invoke user code.
pub fn isMetadataEvent(kind: u32) bool {
    return switch (kind) {
        event.Kind.activity_retry_scheduled, event.Kind.child_started, event.Kind.workflow_terminated, event.Kind.compensation_plan_started, event.Kind.compensation_step_completed, event.Kind.compensation_step_failed, event.Kind.compensation_plan_completed, event.Kind.compensation_plan_failed => true,
        else => false,
    };
}

/// Looks up the exact persisted definition version before processing any history.
/// Callers block the claimed task when this returns `DefinitionUnavailable`.
pub fn processRegisteredDecisions(registry: *const definition.Registry, definition_id: u64, definition_version: u32, workflow_id: @import("../core/stable_id.zig").StableId, initial_state: []const u8, last_processed_sequence: u64, decisions: []const event.Event, command_storage: []command.Command) (Error || anyerror)!TransitionResult {
    const def = registry.find(definition_id, definition_version) catch return error.DefinitionUnavailable;
    return processDecisions(def, workflow_id, initial_state, last_processed_sequence, decisions, command_storage);
}

/// Converts deterministic commands into Task 17 persistence work. Activities, timers, and outbox records
/// are persisted only; this worker never executes or publishes them.
pub fn normalizeCommands(allocator: std.mem.Allocator, workflow_id: @import("../core/stable_id.zig").StableId, decision_sequence: u64, scheduled_utc_ms: i64, commands: []const command.Command) (Error || std.mem.Allocator.Error || error{ InvalidTimerCommand, InvalidChildCommand })!persistence.ScheduledWork {
    var activities: std.ArrayListUnmanaged(persistence.ActivityTask) = .empty;
    errdefer activities.deinit(allocator);
    var timers: std.ArrayListUnmanaged(persistence.Timer) = .empty;
    errdefer timers.deinit(allocator);
    var outbox: std.ArrayListUnmanaged(persistence.OutboxMessage) = .empty;
    errdefer outbox.deinit(allocator);
    var children: std.ArrayListUnmanaged(persistence.ChildStart) = .empty;
    errdefer children.deinit(allocator);
    var child_cancellations: std.ArrayListUnmanaged(persistence.ChildCancel) = .empty;
    errdefer child_cancellations.deinit(allocator);
    var compensations: std.ArrayListUnmanaged(persistence.Compensation) = .empty;
    errdefer compensations.deinit(allocator);
    for (commands) |value| {
        if (decision_sequence > std.math.maxInt(u32) or value.sequence > std.math.maxInt(u32)) return error.CommandSequenceOverflow;
        const global_sequence = (decision_sequence << 32) | value.sequence;
        const id = derivedId(workflow_id, global_sequence, value.kind);
        switch (value.kind) {
            command.Kind.schedule_activity => try activities.append(allocator, .{ .task_id = id, .command_sequence = global_sequence, .schema = value.payload.schema, .payload = value.payload.bytes }),
            command.Kind.schedule_timer => {
                const timer = try command.decodeTimer(value.payload.bytes);
                const delay: i64 = @intCast(@min(timer.delay_ms, @as(u64, std.math.maxInt(i64))));
                try timers.append(allocator, .{ .timer_id = id, .fire_at_utc_ms = std.math.add(i64, scheduled_utc_ms, delay) catch std.math.maxInt(i64), .schema = value.payload.schema, .payload = timer.payload });
            },
            command.Kind.send_signal => try outbox.append(allocator, .{ .message_id = id, .payload = value.payload.bytes }),
            command.Kind.start_child => {
                const decoded = try child.decodeStart(value.payload.bytes);
                try children.append(allocator, .{ .workflow_id = derivedId(workflow_id, global_sequence, value.kind), .task_id = derivedId(workflow_id, global_sequence, value.kind + 1), .event_id = derivedId(workflow_id, global_sequence, value.kind + 2), .definition_id = decoded.definition_id, .definition_version = decoded.definition_version, .schema = decoded.input.schema, .payload = decoded.input.bytes, .parent_close_policy = @intFromEnum(decoded.parent_close_policy) });
            },
            command.Kind.cancel_child => try child_cancellations.append(allocator, .{ .workflow_id = try child.decodeCancel(value.payload.bytes), .event_id = derivedId(workflow_id, global_sequence, value.kind) }),
            command.Kind.compensate => try compensations.append(allocator, .{ .plan_id = derivedId(workflow_id, decision_sequence, command.Kind.compensate), .task_id = id, .command_sequence = global_sequence, .activity_type = value.payload.schema.id, .schema = value.payload.schema, .payload = value.payload.bytes, .input_hash = core.hash.content(value.payload.bytes), .index = @intCast(value.sequence) }),
            else => {},
        }
    }
    return .{ .activities = try activities.toOwnedSlice(allocator), .timers = try timers.toOwnedSlice(allocator), .outbox = try outbox.toOwnedSlice(allocator), .children = try children.toOwnedSlice(allocator), .child_cancellations = try child_cancellations.toOwnedSlice(allocator), .compensations = try compensations.toOwnedSlice(allocator) };
}

/// Releases collections returned by normalizeCommands. Payload bytes remain borrowed.
pub fn deinitScheduledWork(allocator: std.mem.Allocator, value: *persistence.ScheduledWork) void {
    allocator.free(value.activities);
    allocator.free(value.timers);
    allocator.free(value.outbox);
    allocator.free(value.children);
    allocator.free(value.child_cancellations);
    allocator.free(value.compensations);
    value.* = .{};
}

/// Builds a verified snapshot owned by the caller's state buffer.
pub fn makeSnapshot(workflow_id: @import("../core/stable_id.zig").StableId, event_sequence: u64, definition_version: u32, state: []const u8) snapshot.Snapshot {
    return .{ .workflow_id = workflow_id, .event_sequence = event_sequence, .definition_version = definition_version, .state = state, .checksum = snapshot.checksum(workflow_id, event_sequence, definition_version, state) };
}

fn derivedId(workflow_id: @import("../core/stable_id.zig").StableId, sequence: u64, kind: u32) @import("../core/stable_id.zig").StableId {
    var bytes = workflow_id.toBytes();
    const mix = sequence ^ (@as(u64, kind) << 32);
    const low = std.mem.readInt(u64, bytes[8..16], .big) ^ mix;
    std.mem.writeInt(u64, bytes[8..16], low, .big);
    return .fromBytes(bytes);
}

test "checkpoint policy covers interval and terminal transitions" {
    try std.testing.expect(!needsCheckpoint(10, 73, .running));
    try std.testing.expect(needsCheckpoint(10, 74, .running));
    try std.testing.expect(needsCheckpoint(74, 75, .completed));
}

test "processes every decision in sequence and checkpoints terminal state" {
    const schema = @import("../core/schema.zig").SchemaKey{ .id = 1, .version = 1 };
    const def = definition.Definition{ .id = 1, .stable_name = "worker.test", .version = 1, .schemas = .{ .state = schema, .event = schema, .command = schema }, .transition = struct {
        fn transition(_: *definition.WorkflowContext, _: []const u8, input: event.Event) !definition.Outcome {
            return .{ .new_state = if (input.sequence == 2) "done" else "waiting", .status = if (input.sequence == 2) .completed else .running };
        }
    }.transition };
    const events = [_]event.Event{ .{ .sequence = 1, .kind = event.Kind.started, .utc_ms = 1, .payload = .{ .schema = schema, .bytes = "" } }, .{ .sequence = 2, .kind = event.Kind.signal_received, .utc_ms = 2, .payload = .{ .schema = schema, .bytes = "" } } };
    var commands: [4]command.Command = undefined;
    const result = try processDecisions(def, .{ .high = 1, .low = 2 }, "", 0, &events, &commands);
    try std.testing.expectEqual(@as(u64, 2), result.last_decision_sequence);
    try std.testing.expect(result.optional_snapshot != null);
    try std.testing.expect(snapshot.verify(result.optional_snapshot.?));
}

test "command sequence is task-wide and waiting checkpoints are durable" {
    const schema = @import("../core/schema.zig").SchemaKey{ .id = 1, .version = 1 };
    const def = definition.Definition{ .id = 1, .stable_name = "worker.commands", .version = 1, .schemas = .{ .state = schema, .event = schema, .command = schema }, .transition = struct {
        fn transition(context: *definition.WorkflowContext, _: []const u8, _: event.Event) !definition.Outcome {
            try context.commands.emit(command.Kind.send_signal, .{ .schema = schema, .bytes = "one" });
            return .{ .new_state = "waiting" };
        }
    }.transition };
    const events = [_]event.Event{
        .{ .sequence = 1, .kind = event.Kind.started, .utc_ms = 1, .payload = .{ .schema = schema, .bytes = "" } },
        .{ .sequence = 2, .kind = event.Kind.signal_received, .utc_ms = 2, .payload = .{ .schema = schema, .bytes = "" } },
    };
    var commands: [2]command.Command = undefined;
    const result = try processDecisions(def, .{ .high = 1, .low = 2 }, "", 0, &events, &commands);
    try std.testing.expectEqual(@as(u64, 1), result.commands[0].sequence);
    try std.testing.expectEqual(@as(u64, 2), result.commands[1].sequence);
    try std.testing.expect(result.optional_snapshot != null);
}
