const spindle = @import("spindle");

pub const definition_id: u64 = 0x6761_6d65_2e6c_6f67;
pub const version: u32 = 3;
pub const state_schema = spindle.core.schema.SchemaKey{ .id = 0x6c6f_6769_6e2e_7374, .version = 3 };
pub const event_schema = spindle.core.schema.SchemaKey{ .id = 0x6c6f_6769_6e2e_6576, .version = 3 };
pub const command_schema = spindle.core.schema.SchemaKey{ .id = 0x6c6f_6769_6e2e_636d, .version = 3 };

pub const idle = "idle";
pub const waiting = "waiting";
pub const authenticated = "authenticated";
pub const timed_out = "timed_out";

/// The v3 login fixture has no external effects; emitted commands are its golden protocol output.
pub fn transition(context: *spindle.workflow.definition.WorkflowContext, state: []const u8, input: spindle.workflow.event.Event) !spindle.workflow.definition.Outcome {
    _ = state;
    switch (input.kind) {
        spindle.workflow.event.Kind.started => {
            try context.commands.emit(spindle.workflow.command.Kind.schedule_activity, .{ .schema = command_schema, .bytes = "authenticate" });
            return .{ .new_state = waiting };
        },
        spindle.workflow.event.Kind.activity_completed => {
            try context.commands.emit(spindle.workflow.command.Kind.complete, .{ .schema = command_schema, .bytes = "logged-in" });
            return .{ .new_state = authenticated, .status = .completed };
        },
        spindle.workflow.event.Kind.activity_failed => {
            try context.commands.emit(spindle.workflow.command.Kind.compensate, .{ .schema = command_schema, .bytes = "revoke-session" });
            return .{ .new_state = timed_out, .status = .failed };
        },
        else => return .{ .new_state = waiting },
    }
}

pub const definition = spindle.workflow.Definition{
    .id = definition_id,
    .stable_name = "game.login",
    .version = version,
    .schemas = .{ .state = state_schema, .event = event_schema, .command = command_schema },
    .transition = transition,
};
