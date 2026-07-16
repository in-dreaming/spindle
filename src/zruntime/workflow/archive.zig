const std = @import("std");
const core = @import("../core/root.zig");
const sqlite = @import("sqlite.zig");

/// Fixed archive envelope version. Records are independently length-delimited and checksummed.
pub const format_version: u32 = 1;
pub const Record = struct { sequence: u64, kind: u32, utc_ms: i64, schema: core.schema.SchemaKey, payload: []const u8 };
pub const Manifest = struct { first_sequence: u64, last_sequence: u64, record_count: u64, checksum: u64 };
pub const max_archive_bytes: usize = 16 * 1024 * 1024;

/// Encodes records in canonical sequence order. Callers must verify before publishing a manifest.
pub fn encode(allocator: std.mem.Allocator, records: []const Record) ![]u8 {
    if (records.len == 0) return error.EmptyArchive;
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(allocator);
    var header: [12]u8 = undefined;
    @memcpy(header[0..4], "SPAR");
    std.mem.writeInt(u32, header[4..8], format_version, .big);
    std.mem.writeInt(u32, header[8..12], @intCast(records.len), .big);
    try bytes.appendSlice(allocator, &header);
    var expected = records[0].sequence;
    for (records) |record| {
        if (record.sequence != expected) return error.InvalidSequence;
        expected += 1;
        var fixed: [36]u8 = undefined;
        std.mem.writeInt(u64, fixed[0..8], record.sequence, .big);
        std.mem.writeInt(u32, fixed[8..12], record.kind, .big);
        std.mem.writeInt(i64, fixed[12..20], record.utc_ms, .big);
        std.mem.writeInt(u64, fixed[20..28], record.schema.id, .big);
        std.mem.writeInt(u32, fixed[28..32], record.schema.version, .big);
        std.mem.writeInt(u32, fixed[32..36], @intCast(record.payload.len), .big);
        try bytes.appendSlice(allocator, &fixed);
        try bytes.appendSlice(allocator, record.payload);
    }
    const checksum = core.hash.content(bytes.items);
    var trailer: [8]u8 = undefined;
    std.mem.writeInt(u64, &trailer, checksum, .big);
    try bytes.appendSlice(allocator, &trailer);
    return bytes.toOwnedSlice(allocator);
}

/// Validates the complete envelope, checksum, and continuous record sequence.
pub fn verify(bytes: []const u8) !Manifest {
    if (bytes.len < 20 or !std.mem.eql(u8, bytes[0..4], "SPAR") or std.mem.readInt(u32, bytes[4..8], .big) != format_version) return error.InvalidArchive;
    const count = std.mem.readInt(u32, bytes[8..12], .big);
    const trailer: *const [8]u8 = @ptrCast(bytes.ptr + bytes.len - 8);
    const wanted = std.mem.readInt(u64, trailer, .big);
    if (core.hash.content(bytes[0 .. bytes.len - 8]) != wanted) return error.ChecksumMismatch;
    var offset: usize = 12;
    var first: u64 = 0;
    var previous: u64 = 0;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (offset + 36 > bytes.len - 8) return error.InvalidArchive;
        const sequence = readInt(u64, bytes, offset);
        const payload_len: usize = readInt(u32, bytes, offset + 32);
        if (i == 0) first = sequence else if (sequence != previous + 1) return error.InvalidSequence;
        previous = sequence;
        offset += 36;
        if (payload_len > bytes.len - 8 - offset) return error.InvalidArchive;
        offset += payload_len;
    }
    if (offset != bytes.len - 8) return error.InvalidArchive;
    return .{ .first_sequence = first, .last_sequence = previous, .record_count = count, .checksum = wanted };
}

/// Decodes a previously verified archive into caller-owned payload records.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) ![]Record {
    const manifest = try verify(bytes);
    var records: std.ArrayListUnmanaged(Record) = .empty;
    errdefer {
        for (records.items) |record| allocator.free(record.payload);
        records.deinit(allocator);
    }
    var offset: usize = 12;
    var i: u64 = 0;
    while (i < manifest.record_count) : (i += 1) {
        const payload_len: usize = readInt(u32, bytes, offset + 32);
        const payload = try allocator.dupe(u8, bytes[offset + 36 .. offset + 36 + payload_len]);
        errdefer allocator.free(payload);
        try records.append(allocator, .{ .sequence = readInt(u64, bytes, offset), .kind = readInt(u32, bytes, offset + 8), .utc_ms = readInt(i64, bytes, offset + 12), .schema = .{ .id = readInt(u64, bytes, offset + 20), .version = readInt(u32, bytes, offset + 28) }, .payload = payload });
        offset += 36 + payload_len;
    }
    return records.toOwnedSlice(allocator);
}

pub fn deinitRecords(allocator: std.mem.Allocator, records: []const Record) void {
    for (records) |record| allocator.free(record.payload);
    allocator.free(records);
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    const width = @divExact(@typeInfo(T).int.bits, 8);
    const pointer: *const [width]u8 = @ptrCast(bytes.ptr + offset);
    return std.mem.readInt(T, pointer, .big);
}

/// Atomic local filesystem artifact store used only by the archive feature.
pub const LocalArtifactStore = struct {
    io: std.Io,
    directory: []const u8,
    pub fn put(self: LocalArtifactStore, location: []const u8, bytes: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.directory);
        var final_buf: [std.fs.max_path_bytes]u8 = undefined;
        const final = try std.fmt.bufPrint(&final_buf, "{s}/{s}", .{ self.directory, location });
        if (std.Io.Dir.cwd().openFile(self.io, final, .{})) |existing| {
            existing.close(self.io);
            return;
        } else |err| if (err != error.FileNotFound) return err;
        var pending_buf: [std.fs.max_path_bytes]u8 = undefined;
        const pending = try std.fmt.bufPrint(&pending_buf, "{s}.pending", .{final});
        var file = try std.Io.Dir.cwd().createFile(self.io, pending, .{ .truncate = true });
        errdefer {
            file.close(self.io);
            std.Io.Dir.cwd().deleteFile(self.io, pending) catch {};
        }
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
        file.close(self.io);
        try std.Io.Dir.cwd().rename(pending, std.Io.Dir.cwd(), final, self.io);
    }
    pub fn get(self: LocalArtifactStore, allocator: std.mem.Allocator, location: []const u8) ![]u8 {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.directory, location });
        const buffer = try allocator.alloc(u8, max_archive_bytes);
        defer allocator.free(buffer);
        return allocator.dupe(u8, try std.Io.Dir.cwd().readFile(self.io, path, buffer));
    }
};

/// Archives one eligible completed workflow after durable write and read-back verification.
pub fn archiveCompleted(allocator: std.mem.Allocator, store: *sqlite.Store, artifacts: anytype, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, retention_before_utc_ms: i64) !Manifest {
    const hot = try store.readHistory(allocator, tenant, namespace, workflow_id);
    defer {
        for (hot) |record| allocator.free(record.payload);
        allocator.free(hot);
    }
    const records = try allocator.alloc(Record, hot.len);
    defer allocator.free(records);
    for (hot, 0..) |record, i| records[i] = .{ .sequence = record.sequence, .kind = record.kind, .utc_ms = record.utc_ms, .schema = record.schema, .payload = record.payload };
    const bytes = try encode(allocator, records);
    defer allocator.free(bytes);
    const manifest = try verify(bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var name_buf: [64]u8 = undefined;
    const name = try std.fmt.bufPrint(&name_buf, "{x}", .{digest});
    try artifacts.put(name, bytes);
    const read_back = try artifacts.get(allocator, name);
    defer allocator.free(read_back);
    const verified = try verify(read_back);
    if (!manifestEqual(verified, manifest)) return error.ArchiveManifestMismatch;
    try store.commitArchive(.{ .workflow_id = workflow_id, .tenant = tenant, .namespace = namespace, .first_sequence = manifest.first_sequence, .last_sequence = manifest.last_sequence, .location = name, .checksum = manifest.checksum, .event_count = manifest.record_count, .retention_before_utc_ms = retention_before_utc_ms });
    return manifest;
}

/// Reads verified archives plus the hot tail and rejects gaps before replay.
pub fn readHistory(allocator: std.mem.Allocator, store: *sqlite.Store, artifacts: anytype, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, max_events: usize) ![]Record {
    const manifests = try store.archiveRecords(allocator, tenant, namespace, workflow_id);
    defer {
        for (manifests) |item| allocator.free(item.location);
        allocator.free(manifests);
    }
    var result: std.ArrayListUnmanaged(Record) = .empty;
    errdefer {
        for (result.items) |record| allocator.free(record.payload);
        result.deinit(allocator);
    }
    var expected: u64 = 1;
    for (manifests) |item| {
        const bytes = try artifacts.get(allocator, item.location);
        defer allocator.free(bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
        var location_buf: [64]u8 = undefined;
        const canonical_location = try std.fmt.bufPrint(&location_buf, "{x}", .{digest});
        if (!std.mem.eql(u8, item.location, canonical_location)) return error.ArchiveLocationMismatch;
        const verified = try verify(bytes);
        if (verified.first_sequence != item.first_sequence or verified.last_sequence != item.last_sequence or verified.record_count != item.event_count or verified.checksum != item.checksum) return error.ArchiveManifestMismatch;
        const decoded = try decode(allocator, bytes);
        var transferred: usize = 0;
        defer {
            for (decoded[transferred..]) |record| allocator.free(record.payload);
            allocator.free(decoded);
        }
        for (decoded) |record| {
            if (record.sequence != expected) return error.InvalidSequence;
            expected += 1;
            try result.append(allocator, record);
            transferred += 1;
        }
    }
    const hot = store.readHistory(allocator, tenant, namespace, workflow_id) catch |err| switch (err) {
        error.NotFound => &.{},
        else => return err,
    };
    defer if (hot.len != 0) {
        for (hot) |record| allocator.free(record.payload);
        allocator.free(hot);
    };
    for (hot) |record| {
        if (record.sequence != expected) return error.InvalidSequence;
        expected += 1;
        try result.append(allocator, .{ .sequence = record.sequence, .kind = record.kind, .utc_ms = record.utc_ms, .schema = record.schema, .payload = try allocator.dupe(u8, record.payload) });
    }
    if (result.items.len > max_events) return error.ReplayLimitExceeded;
    return result.toOwnedSlice(allocator);
}

fn manifestEqual(a: Manifest, b: Manifest) bool {
    return a.first_sequence == b.first_sequence and a.last_sequence == b.last_sequence and a.record_count == b.record_count and a.checksum == b.checksum;
}
