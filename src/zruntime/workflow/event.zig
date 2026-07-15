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
};

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
