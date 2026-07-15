const std = @import("std");
const core = @import("../core/root.zig");

/// Persisted event kind IDs. Their numeric values are part of the workflow wire protocol.
pub const Kind = struct {
    pub const started: u32 = 1;
    pub const signal_received: u32 = 2;
    pub const activity_completed: u32 = 3;
    pub const activity_failed: u32 = 4;
    pub const timer_fired: u32 = 5;
    pub const command_recorded: u32 = 6;
    pub const random_recorded: u32 = 7;
    pub const cancellation_requested: u32 = 8;
    /// A deterministic retry decision. It is replay metadata, not workflow input.
    pub const activity_retry_scheduled: u32 = 9;
    pub const child_started: u32 = 10;
    pub const child_completed: u32 = 11;
    pub const child_failed: u32 = 12;
    pub const child_cancelled: u32 = 13;
    pub const workflow_terminated: u32 = 14;
    pub const compensation_plan_started: u32 = 15;
    pub const compensation_step_completed: u32 = 16;
    pub const compensation_step_failed: u32 = 17;
    pub const compensation_plan_completed: u32 = 18;
    pub const compensation_plan_failed: u32 = 19;
    pub const definition_migrated: u32 = 20;
};

/// Schema for explicit definition-switch facts. The encoded payload is stable.
pub const definition_migrated_schema = core.schema.SchemaKey{ .id = 0x6465_666d_6967_7261, .version = 1 };
/// Schema for an operator termination fact. The encoded payload is stable.
pub const workflow_terminated_schema = core.schema.SchemaKey{ .id = 0x7766_7465_726d_696e, .version = 1 };

/// Version/hash/principal/reason metadata persisted with a definition switch.
pub const DefinitionMigrated = struct { version: u32, hash: u64, principal: []const u8, reason: []const u8 };
/// Principal/reason metadata persisted with an operator termination.
pub const WorkflowTerminated = struct { principal: []const u8, reason: []const u8 };

/// Writes a stable length-prefixed migration marker payload.
pub fn encodeDefinitionMigrated(writer: *std.Io.Writer, value: DefinitionMigrated) !void {
    var fixed: [16]u8 = undefined;
    std.mem.writeInt(u32, fixed[0..4], value.version, .big);
    std.mem.writeInt(u64, fixed[4..12], value.hash, .big);
    std.mem.writeInt(u16, fixed[12..14], @intCast(value.principal.len), .big);
    std.mem.writeInt(u16, fixed[14..16], @intCast(value.reason.len), .big);
    try writer.writeAll(&fixed);
    try writer.writeAll(value.principal);
    try writer.writeAll(value.reason);
}

pub fn encodeDefinitionMigratedBytes(buffer: []u8, value: DefinitionMigrated) error{PayloadTooLarge}![]const u8 {
    if (value.principal.len > std.math.maxInt(u16) or value.reason.len > std.math.maxInt(u16) or 16 + value.principal.len + value.reason.len > buffer.len) return error.PayloadTooLarge;
    std.mem.writeInt(u32, buffer[0..4], value.version, .big);
    std.mem.writeInt(u64, buffer[4..12], value.hash, .big);
    std.mem.writeInt(u16, buffer[12..14], @intCast(value.principal.len), .big);
    std.mem.writeInt(u16, buffer[14..16], @intCast(value.reason.len), .big);
    @memcpy(buffer[16 .. 16 + value.principal.len], value.principal);
    @memcpy(buffer[16 + value.principal.len .. 16 + value.principal.len + value.reason.len], value.reason);
    return buffer[0 .. 16 + value.principal.len + value.reason.len];
}

pub fn encodeWorkflowTerminatedBytes(buffer: []u8, value: WorkflowTerminated) error{PayloadTooLarge}![]const u8 {
    if (value.principal.len > std.math.maxInt(u16) or value.reason.len > std.math.maxInt(u16) or 4 + value.principal.len + value.reason.len > buffer.len) return error.PayloadTooLarge;
    std.mem.writeInt(u16, buffer[0..2], @intCast(value.principal.len), .big);
    std.mem.writeInt(u16, buffer[2..4], @intCast(value.reason.len), .big);
    @memcpy(buffer[4 .. 4 + value.principal.len], value.principal);
    @memcpy(buffer[4 + value.principal.len .. 4 + value.principal.len + value.reason.len], value.reason);
    return buffer[0 .. 4 + value.principal.len + value.reason.len];
}

/// A schema-qualified payload which aliases caller-owned immutable bytes.
pub const Payload = struct { schema: core.schema.SchemaKey, bytes: []const u8 };

/// Immutable history record. Sequence starts at one and is validated by replay.
pub const Event = struct {
    sequence: u64,
    kind: u32,
    utc_ms: i64,
    payload: Payload,
};

/// Serializes event metadata in fixed network byte order, excluding payload bytes.
pub fn encodeHeader(event: Event) [32]u8 {
    var result: [32]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], event.sequence, .big);
    std.mem.writeInt(u32, result[8..12], event.kind, .big);
    std.mem.writeInt(i64, result[12..20], event.utc_ms, .big);
    std.mem.writeInt(u64, result[20..28], event.payload.schema.id, .big);
    std.mem.writeInt(u32, result[28..32], event.payload.schema.version, .big);
    return result;
}
