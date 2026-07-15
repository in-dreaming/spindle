const std = @import("std");
const core = @import("../core/root.zig");
const key = @import("resource_key.zig");
const version = @import("version.zig");

pub const schema_id: u64 = 0x7370_696e_646c_726d;
pub const schema_version: u32 = 1;

/// Persistable resource metadata. Artifact locations are stable logical locations, never pointers.
pub const ResourceManifest = struct {
    key: key.ResourceKey,
    version: version.ResourceVersion,
    artifact_location: []const u8,
    pub fn registerSchema(registry: *core.registry.Registry) !void {
        try registry.register(.{ .key = .{ .id = schema_id, .version = schema_version }, .stable_name = "spindle.resource_manifest" }, null);
    }
    pub fn encode(self: ResourceManifest, allocator: std.mem.Allocator) ![]u8 {
        var payload: std.ArrayListUnmanaged(u8) = .empty;
        defer payload.deinit(allocator);
        try self.key.encode(&payload, allocator);
        var generation: [8]u8 = undefined;
        std.mem.writeInt(u64, &generation, self.version.generation, .big);
        try payload.appendSlice(allocator, &generation);
        try payload.append(allocator, @intFromEnum(self.version.state));
        try payload.append(allocator, if (self.version.content_hash == null) 0 else 1);
        if (self.version.content_hash) |hash| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, hash, .big);
            try payload.appendSlice(allocator, &bytes);
        }
        const producer = self.version.producer_fingerprint.toBytes();
        try payload.appendSlice(allocator, &producer);
        if (self.artifact_location.len > std.math.maxInt(u32)) return error.ArtifactLocationTooLong;
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(self.artifact_location.len), .big);
        try payload.appendSlice(allocator, &len);
        try payload.appendSlice(allocator, self.artifact_location);
        return core.schema.encode(allocator, .{ .id = schema_id, .version = schema_version }, payload.items);
    }
    /// Verifies envelope integrity and that this exact manifest schema is registered. The payload
    /// aliases `bytes`; callers may parse it only while the input remains alive.
    pub fn validateEncoded(registry: *const core.registry.Registry, bytes: []const u8, max_payload_len: usize) ![]const u8 {
        const envelope = try core.schema.decode(bytes, max_payload_len);
        if (envelope.schema.id != schema_id) return error.UnknownSchema;
        if (envelope.schema.version != schema_version) return error.UnknownVersion;
        if (registry.find(schema_id, schema_version) == null) return error.UnknownSchema;
        return envelope.payload;
    }
};

test "resource manifest uses a registered stable envelope" {
    var registry = core.registry.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try ResourceManifest.registerSchema(&registry);
    try std.testing.expect(registry.find(schema_id, schema_version) != null);
    const value = ResourceManifest{ .key = key.ResourceKey.named(.custom, core.StableId.zero, "fixture"), .version = .{ .generation = 3, .content_hash = 9 }, .artifact_location = "mem://fixture" };
    const bytes = try value.encode(std.testing.allocator);
    defer std.testing.allocator.free(bytes);
    const envelope = try core.schema.decode(bytes, 1024);
    try std.testing.expectEqual(schema_id, envelope.schema.id);
    _ = try ResourceManifest.validateEncoded(&registry, bytes, 1024);
    const unknown = try core.schema.encode(std.testing.allocator, .{ .id = schema_id, .version = schema_version + 1 }, envelope.payload);
    defer std.testing.allocator.free(unknown);
    try std.testing.expectError(error.UnknownVersion, ResourceManifest.validateEncoded(&registry, unknown, 1024));
    bytes[bytes.len - 1] +%= 1;
    try std.testing.expectError(error.ChecksumMismatch, core.schema.decode(bytes, 1024));
}
