const spindle = @import("spindle");

pub const definition_id: u64 = 0x6368_6563_6b70_6f69;
pub const version: u32 = 1;
pub const schema = spindle.core.schema.SchemaKey{ .id = definition_id, .version = version };

/// Explicit state machine used to validate worker-owned checkpoint creation.
pub fn transition(_: *spindle.workflow.definition.WorkflowContext, state: []const u8, input: spindle.workflow.event.Event) !spindle.workflow.definition.Outcome {
    if (input.kind == spindle.workflow.event.Kind.cancellation_requested) return .{ .new_state = "cancelled", .status = .cancelled };
    return .{ .new_state = if (state.len == 0) "waiting" else state };
}

pub const definition = spindle.workflow.Definition{ .id = definition_id, .stable_name = "test.checkpoint", .version = version, .schemas = .{ .state = schema, .event = schema, .command = schema }, .transition = transition };
