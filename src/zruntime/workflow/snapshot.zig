const std = @import("std");
const core = @import("../core/root.zig");

/// Replay acceleration data. History remains authoritative and is never replaced by this object.
pub const Snapshot = struct { workflow_id: core.StableId, event_sequence: u64, definition_version: u32, state: []const u8, checksum: u64 };

/// Fixed-width persistent snapshot header: ID, history sequence, definition version, and checksum.
pub fn encodeHeader(value: Snapshot) [36]u8 {
    var bytes: [36]u8 = undefined;
    @memcpy(bytes[0..16], &value.workflow_id.toBytes());
    std.mem.writeInt(u64, bytes[16..24], value.event_sequence, .big);
    std.mem.writeInt(u32, bytes[24..28], value.definition_version, .big);
    std.mem.writeInt(u64, bytes[28..36], value.checksum, .big);
    return bytes;
}
pub fn checksum(id: core.StableId, sequence: u64, version: u32, state: []const u8) u64 {
    var bytes: [28]u8 = undefined;
    @memcpy(bytes[0..16], &id.toBytes());
    std.mem.writeInt(u64, bytes[16..24], sequence, .big);
    std.mem.writeInt(u32, bytes[24..28], version, .big);
    return core.hash.content(bytes[0..]) ^ core.hash.content(state);
}
pub fn verify(value: Snapshot) bool {
    return value.checksum == checksum(value.workflow_id, value.event_sequence, value.definition_version, value.state);
}
