const std = @import("std");
const definition = @import("definition.zig");
const event = @import("event.zig");
const command = @import("command.zig");
const snapshot = @import("snapshot.zig");

pub const Failure = struct { sequence: u64, field: []const u8 };
pub const Result = struct { status: @import("instance.zig").Status, last_sequence: u64 };
/// The persisted command-record event corresponding to one input history event.
pub const CommandEvent = struct { input_sequence: u64, commands: []const command.Command };

/// Replays ordered history and verifies every transition-generated command byte-for-byte.
pub fn verify(def: definition.Definition, initial_state: []const u8, value_snapshot: ?snapshot.Snapshot, history: []const event.Event, recorded: []const CommandEvent, command_storage: []command.Command, random_values: []const u64) (error{ InvalidSnapshot, InvalidSequence, CommandMismatch, MissingCommandRecord } || anyerror)!Result {
    var state = initial_state;
    var expected_sequence: u64 = 1;
    if (value_snapshot) |saved| {
        if (!snapshot.verify(saved) or saved.definition_version != def.version) return error.InvalidSnapshot;
        state = saved.state;
        expected_sequence = saved.event_sequence + 1;
    }
    var status: @import("instance.zig").Status = .running;
    for (history, 0..) |input, index| {
        if (input.sequence != expected_sequence) return error.InvalidSequence;
        expected_sequence += 1;
        var output = command.Buffer.init(command_storage);
        var context = definition.WorkflowContext{ .logical_utc_ms = input.utc_ms, .random_values = random_values, .commands = &output };
        const transition = try def.transition(&context, state, input);
        state = transition.new_state;
        status = transition.status;
        _ = index;
        var wanted: ?[]const command.Command = null;
        for (recorded) |record| if (record.input_sequence == input.sequence) {
            if (wanted != null) return error.MissingCommandRecord;
            wanted = record.commands;
        };
        const expected = wanted orelse return error.MissingCommandRecord;
        if (expected.len != output.slice().len) return error.CommandMismatch;
        for (expected, output.slice()) |left, right| if (!command.eql(left, right)) return error.CommandMismatch;
    }
    return .{ .status = status, .last_sequence = expected_sequence - 1 };
}
