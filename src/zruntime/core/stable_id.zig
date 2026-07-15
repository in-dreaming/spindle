const std = @import("std");

/// A UUIDv7-compatible, cross-process identifier. Bytes are always big-endian.
pub const StableId = struct {
    high: u64,
    low: u64,

    pub const zero = StableId{ .high = 0, .low = 0 };

    /// Serializes this ID in network byte order for persistent formats.
    pub fn toBytes(self: StableId) [16]u8 {
        var result: [16]u8 = undefined;
        std.mem.writeInt(u64, result[0..8], self.high, .big);
        std.mem.writeInt(u64, result[8..16], self.low, .big);
        return result;
    }

    /// Parses 16 network-order bytes from a persistent format.
    pub fn fromBytes(bytes: [16]u8) StableId {
        return .{
            .high = std.mem.readInt(u64, bytes[0..8], .big),
            .low = std.mem.readInt(u64, bytes[8..16], .big),
        };
    }

    /// Parses canonical UUID text (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`).
    pub fn parse(text: []const u8) error{InvalidStableId}!StableId {
        if (text.len != 36 or text[8] != '-' or text[13] != '-' or text[18] != '-' or text[23] != '-') return error.InvalidStableId;
        var bytes: [16]u8 = undefined;
        var input_index: usize = 0;
        var output_index: usize = 0;
        while (input_index < text.len) {
            if (text[input_index] == '-') {
                input_index += 1;
                continue;
            }
            if (input_index + 1 >= text.len or output_index == bytes.len) return error.InvalidStableId;
            bytes[output_index] = (try nibble(text[input_index])) << 4 | try nibble(text[input_index + 1]);
            input_index += 2;
            output_index += 1;
        }
        if (output_index != bytes.len) return error.InvalidStableId;
        return fromBytes(bytes);
    }

    /// Writes canonical lower-case UUID text.
    pub fn format(self: StableId, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const digits = "0123456789abcdef";
        const bytes = self.toBytes();
        for (bytes, 0..) |byte, index| {
            if (index == 4 or index == 6 or index == 8 or index == 10) try writer.writeByte('-');
            try writer.writeByte(digits[byte >> 4]);
            try writer.writeByte(digits[byte & 0x0f]);
        }
    }
};

fn nibble(byte: u8) error{InvalidStableId}!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => error.InvalidStableId,
    };
}

/// Generates time-ordered UUIDv7-compatible IDs. Calls are safe from multiple threads.
pub const Generator = struct {
    mutex: std.atomic.Mutex = .unlocked,
    last_ms: u64 = 0,
    sequence: u16 = 0,

    /// Generates an ID using caller-provided entropy and UTC milliseconds.
    pub fn next(self: *Generator, utc_ms: i64, random: std.Random) StableId {
        lock(&self.mutex);
        defer self.mutex.unlock();

        const observed: u64 = if (utc_ms <= 0) 0 else @intCast(utc_ms);
        if (observed > self.last_ms) {
            self.last_ms = observed;
            self.sequence = random.intRangeLessThan(u16, 0, 1 << 12);
        } else {
            if (self.sequence == 0x0fff) {
                self.last_ms +%= 1;
                self.sequence = random.intRangeLessThan(u16, 0, 1 << 12);
            } else {
                self.sequence += 1;
            }
        }

        var bytes: [16]u8 = undefined;
        const timestamp = self.last_ms & 0x0000_ffff_ffff_ffff;
        bytes[0] = @truncate(timestamp >> 40);
        bytes[1] = @truncate(timestamp >> 32);
        bytes[2] = @truncate(timestamp >> 24);
        bytes[3] = @truncate(timestamp >> 16);
        bytes[4] = @truncate(timestamp >> 8);
        bytes[5] = @truncate(timestamp);
        bytes[6] = 0x70 | @as(u8, @truncate(self.sequence >> 8));
        bytes[7] = @truncate(self.sequence);
        random.bytes(bytes[8..]);
        bytes[8] = (bytes[8] & 0x3f) | 0x80;
        return StableId.fromBytes(bytes);
    }
};

fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

test "stable id canonical text and bytes round trip" {
    const value = StableId{ .high = 0x0123456789abcdef, .low = 0xfedcba9876543210 };
    const bytes = value.toBytes();
    try std.testing.expectEqual(value, StableId.fromBytes(bytes));
    try std.testing.expectEqual(value, try StableId.parse("01234567-89ab-cdef-fedc-ba9876543210"));
}

test "generator is ordered through clock rollback" {
    var generator: Generator = .{};
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();
    const first = generator.next(100, random);
    const second = generator.next(99, random);
    try std.testing.expect(std.math.order(first.high, second.high) != .gt);
}
