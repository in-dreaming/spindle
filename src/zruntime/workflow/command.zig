const std = @import("std");
const event = @import("event.zig");

/// Persisted command kind IDs. Workers must use these IDs, never enum ordinals.
pub const Kind = struct {
    pub const schedule_activity: u32 = 1;
    pub const schedule_timer: u32 = 2;
    pub const send_signal: u32 = 3;
    pub const start_child: u32 = 4;
    pub const complete: u32 = 5;
    pub const fail: u32 = 6;
    pub const compensate: u32 = 7;
    pub const cancel_child: u32 = 8;
};

/// Deterministic command emitted by a transition. Sequence starts at one per workflow task.
pub const Command = struct { sequence: u64, kind: u32, payload: event.Payload };

/// Bounded caller-owned command collector. It does not allocate or perform side effects.
pub const Buffer = struct {
    commands: []Command,
    len: usize = 0,

    pub fn init(storage: []Command) Buffer {
        return .{ .commands = storage };
    }
    pub fn slice(self: *const Buffer) []const Command {
        return self.commands[0..self.len];
    }
    pub fn emit(self: *Buffer, kind: u32, payload: event.Payload) error{CommandCapacityExceeded}!void {
        if (self.len == self.commands.len) return error.CommandCapacityExceeded;
        self.commands[self.len] = .{ .sequence = @intCast(self.len + 1), .kind = kind, .payload = payload };
        self.len += 1;
    }
};

/// Serializes command metadata in fixed network byte order, excluding payload bytes.
pub fn encodeHeader(command: Command) [24]u8 {
    var result: [24]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], command.sequence, .big);
    std.mem.writeInt(u32, result[8..12], command.kind, .big);
    std.mem.writeInt(u64, result[12..20], command.payload.schema.id, .big);
    std.mem.writeInt(u32, result[20..24], command.payload.schema.version, .big);
    return result;
}

/// Exact deterministic comparison used by replay verification.
pub fn eql(left: Command, right: Command) bool {
    return left.sequence == right.sequence and left.kind == right.kind and
        left.payload.schema.id == right.payload.schema.id and left.payload.schema.version == right.payload.schema.version and
        std.mem.eql(u8, left.payload.bytes, right.payload.bytes);
}

/// Encodes a durable timer delay followed by its application payload in fixed network byte order.
pub fn encodeTimer(comptime payload: []const u8, delay_ms: u64) [8 + payload.len]u8 {
    var result: [8 + payload.len]u8 = undefined;
    std.mem.writeInt(u64, result[0..8], delay_ms, .big);
    @memcpy(result[8..], payload);
    return result;
}
pub const DecodedTimer = struct { delay_ms: u64, payload: []const u8 };
pub fn decodeTimer(bytes: []const u8) error{InvalidTimerCommand}!DecodedTimer {
    if (bytes.len < 8) return error.InvalidTimerCommand;
    return .{ .delay_ms = std.mem.readInt(u64, bytes[0..8], .big), .payload = bytes[8..] };
}
