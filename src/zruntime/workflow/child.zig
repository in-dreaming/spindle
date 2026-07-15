const std = @import("std");
const core = @import("../core/root.zig");
const event = @import("event.zig");

/// The durable action applied to an unfinished child when its parent closes.
pub const ParentClosePolicy = enum(u8) { abandon = 1, request_cancel = 2, terminate = 3 };
pub const schema = core.schema.SchemaKey{ .id = 0x6368_696c_645f_7631, .version = 1 };
pub const Start = struct { definition_id: u64, definition_version: u32, input: event.Payload, parent_close_policy: ParentClosePolicy };

/// Encodes a child start command in fixed byte order followed by immutable input bytes.
pub fn encodeStart(comptime input: []const u8, value: Start) [25 + input.len]u8 {
    var result: [25 + input.len]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], value.definition_id, .big);
    std.mem.writeInt(u32, result[8..12], value.definition_version, .big);
    std.mem.writeInt(u64, result[12..20], value.input.schema.id, .big);
    std.mem.writeInt(u32, result[20..24], value.input.schema.version, .big);
    result[24] = @intFromEnum(value.parent_close_policy);
    @memcpy(result[25..], input);
    return result;
}
pub fn decodeStart(bytes: []const u8) error{InvalidChildCommand}!Start {
    if (bytes.len < 25) return error.InvalidChildCommand;
    const policy = std.enums.fromInt(ParentClosePolicy, bytes[24]) orelse return error.InvalidChildCommand;
    return .{ .definition_id = std.mem.readInt(u64, bytes[0..8], .big), .definition_version = std.mem.readInt(u32, bytes[8..12], .big), .input = .{ .schema = .{ .id = std.mem.readInt(u64, bytes[12..20], .big), .version = std.mem.readInt(u32, bytes[20..24], .big) }, .bytes = bytes[25..] }, .parent_close_policy = policy };
}
pub fn decodeCancel(bytes: []const u8) error{InvalidChildCommand}!core.StableId {
    if (bytes.len != 16) return error.InvalidChildCommand;
    var raw: [16]u8 = undefined;
    @memcpy(&raw, bytes);
    return .fromBytes(raw);
}
