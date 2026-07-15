const std = @import("std");
const core = @import("../core/root.zig");

/// File identity combines a namespace and normalized path; path hashes are never used as identity.
pub const FileIdentity = struct {
    namespace: core.StableId,
    path: []const u8,
    hash: u64,

    pub fn init(namespace: core.StableId, path: []const u8) FileIdentity {
        return .{ .namespace = namespace, .path = path, .hash = core.hash.content(path) };
    }
    pub fn eql(a: FileIdentity, b: FileIdentity) bool {
        return a.namespace.high == b.namespace.high and a.namespace.low == b.namespace.low and a.hash == b.hash and std.mem.eql(u8, a.path, b.path);
    }
};

pub const Kind = enum(u8) { file, page, memory_buffer, database_segment, gpu_buffer, texture, network_blob, custom };

/// Structured resource identity. `name` is an opaque stable name for non-file resources.
pub const ResourceKey = struct {
    kind: Kind,
    namespace: core.StableId,
    name: []const u8,
    file: ?FileIdentity = null,
    page: ?u64 = null,
    cached_hash: u64,

    pub fn named(kind: Kind, namespace: core.StableId, name: []const u8) ResourceKey {
        return .{ .kind = kind, .namespace = namespace, .name = name, .cached_hash = core.hash.content(name) };
    }
    pub fn fileKey(identity: FileIdentity) ResourceKey {
        return .{ .kind = .file, .namespace = identity.namespace, .name = identity.path, .file = identity, .cached_hash = identity.hash };
    }
    pub fn pageKey(identity: FileIdentity, page: u64) ResourceKey {
        return .{ .kind = .page, .namespace = identity.namespace, .name = identity.path, .file = identity, .page = page, .cached_hash = identity.hash ^ page };
    }
    pub fn eql(a: ResourceKey, b: ResourceKey) bool {
        if (a.kind != b.kind or a.namespace.high != b.namespace.high or a.namespace.low != b.namespace.low or a.cached_hash != b.cached_hash) return false;
        if (a.page != b.page) return false;
        if (a.file) |file| return b.file != null and file.eql(b.file.?);
        return b.file == null and std.mem.eql(u8, a.name, b.name);
    }
    /// Appends a stable, length-delimited encoding suitable for persistent records.
    pub fn encode(self: ResourceKey, out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        try out.append(allocator, @intFromEnum(self.kind));
        const bytes = self.namespace.toBytes();
        try out.appendSlice(allocator, &bytes);
        try appendBytes(out, allocator, self.name);
        if (self.page) |page| {
            try out.append(allocator, 1);
            var value: [8]u8 = undefined;
            std.mem.writeInt(u64, &value, page, .big);
            try out.appendSlice(allocator, &value);
        } else try out.append(allocator, 0);
    }
};

fn appendBytes(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, bytes: []const u8) !void {
    if (bytes.len > std.math.maxInt(u32)) return error.NameTooLong;
    var length: [4]u8 = undefined;
    std.mem.writeInt(u32, &length, @intCast(bytes.len), .big);
    try out.appendSlice(allocator, &length);
    try out.appendSlice(allocator, bytes);
}

test "resource key collision uses exact identity" {
    const ns = core.StableId.zero;
    const a = ResourceKey.named(.custom, ns, "alpha");
    var b = ResourceKey.named(.custom, ns, "beta");
    b.cached_hash = a.cached_hash;
    try std.testing.expect(!a.eql(b));
}
