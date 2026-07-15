const std = @import("std");
const hash = @import("hash.zig");

/// Stable schema identity. IDs and versions are persisted as unsigned big-endian integers.
pub const SchemaKey = struct { id: u64, version: u32 };

/// Metadata registered for a schema version. `stable_name` must remain valid while registered.
pub const SchemaMeta = struct {
    key: SchemaKey,
    stable_name: []const u8,
};

pub const magic = [4]u8{ 'S', 'P', 'N', 'D' };
pub const format_version: u16 = 1;
pub const header_len: usize = 30;

/// Parsed view over a verified binary envelope. The payload aliases the input bytes.
pub const Envelope = struct {
    schema: SchemaKey,
    payload: []const u8,
};

pub const DecodeError = error{ InvalidMagic, UnsupportedFormat, Truncated, LengthTooLarge, LengthMismatch, ChecksumMismatch };

/// Encodes a self-delimiting binary envelope. Header fields use network byte order.
pub fn encode(allocator: std.mem.Allocator, schema: SchemaKey, payload: []const u8) ![]u8 {
    if (payload.len > std.math.maxInt(u32)) return error.LengthTooLarge;
    const result = try allocator.alloc(u8, header_len + payload.len);
    errdefer allocator.free(result);
    @memcpy(result[0..4], &magic);
    std.mem.writeInt(u16, result[4..6], format_version, .big);
    std.mem.writeInt(u64, result[6..14], schema.id, .big);
    std.mem.writeInt(u32, result[14..18], schema.version, .big);
    std.mem.writeInt(u32, result[18..22], @intCast(payload.len), .big);
    std.mem.writeInt(u64, result[22..30], hash.content(payload), .big);
    @memcpy(result[header_len..], payload);
    return result;
}

/// Decodes a bounded envelope without allocation. The caller selects the permitted payload maximum.
pub fn decode(input: []const u8, max_payload_len: usize) DecodeError!Envelope {
    if (input.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, input[0..4], &magic)) return error.InvalidMagic;
    if (std.mem.readInt(u16, input[4..6], .big) != format_version) return error.UnsupportedFormat;
    const declared: usize = std.mem.readInt(u32, input[18..22], .big);
    if (declared > max_payload_len) return error.LengthTooLarge;
    const total = std.math.add(usize, header_len, declared) catch return error.LengthTooLarge;
    if (input.len != total) return error.LengthMismatch;
    const payload = input[header_len..];
    if (hash.content(payload) != std.mem.readInt(u64, input[22..30], .big)) return error.ChecksumMismatch;
    return .{ .schema = .{ .id = std.mem.readInt(u64, input[6..14], .big), .version = std.mem.readInt(u32, input[14..18], .big) }, .payload = payload };
}

test "envelope golden bytes and corruption handling" {
    const encoded = try encode(std.testing.allocator, .{ .id = 0x0102030405060708, .version = 9 }, "abc");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, &.{ 'S', 'P', 'N', 'D', 0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 0, 0, 0, 9, 0, 0, 0, 3 }, encoded[0..22]);
    try std.testing.expectEqualStrings("abc", (try decode(encoded, 3)).payload);
    encoded[29] +%= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(encoded, 3));
}
