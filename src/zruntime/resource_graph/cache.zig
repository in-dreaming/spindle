const std = @import("std");
const CancellationToken = @import("../executor/cancellation.zig").CancellationToken;

/// Stable content-addressed key. Hex formatting is deliberately fixed width.
pub const Fingerprint = [32]u8;

/// Explicit task inputs used to derive a cross-process cache key. Environment
/// values must be supplied in sorted name order; arbitrary process state is not read.
pub const FingerprintInput = struct {
    task_kind: []const u8,
    task_version: u32,
    canonical_params: []const u8,
    input_versions: []const u64,
    input_hashes: []const u64,
    toolchain: []const u8,
    environment: []const Environment,
};
pub const Environment = struct { name: []const u8, value: []const u8 };

/// Produces a length-delimited SHA-256 fingerprint without maps, pointers, or randomized hashes.
pub fn fingerprint(input: FingerprintInput) !Fingerprint {
    if (input.input_versions.len != input.input_hashes.len) return error.InputVersionHashMismatch;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    try putBytes(&hasher, input.task_kind);
    try putInt(&hasher, input.task_version);
    try putBytes(&hasher, input.canonical_params);
    try putInt(&hasher, @as(u64, @intCast(input.input_versions.len)));
    for (input.input_versions, input.input_hashes) |version, hash| {
        try putInt(&hasher, version);
        try putInt(&hasher, hash);
    }
    try putBytes(&hasher, input.toolchain);
    var previous: ?[]const u8 = null;
    for (input.environment) |entry| {
        if (previous) |name| if (std.mem.order(u8, name, entry.name) != .lt) return error.EnvironmentNotCanonical;
        previous = entry.name;
        try putBytes(&hasher, entry.name);
        try putBytes(&hasher, entry.value);
    }
    var result: Fingerprint = undefined;
    hasher.final(&result);
    return result;
}
fn putInt(hasher: anytype, value: anytype) !void {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .big);
    hasher.update(&bytes);
}
fn putBytes(hasher: anytype, bytes: []const u8) !void {
    try putInt(hasher, @as(u64, @intCast(bytes.len)));
    hasher.update(bytes);
}
pub fn hex(key: Fingerprint, buffer: *[64]u8) []const u8 {
    _ = std.fmt.bufPrint(buffer, "{x}", .{key}) catch unreachable;
    return buffer;
}

/// Validated cache result. The caller owns `bytes` and must free it with its allocator.
pub const Artifact = struct { bytes: []u8, digest: Fingerprint };

/// Remote artifact/blob cache. Calls use Zig's real HTTP(S) client; callers route
/// them through the blocking executor when synchronous use would block a worker.
pub const ArtifactStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    endpoint: []const u8,
    authorization: ?[]const u8 = null,
    retries: u8 = 2,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8) ArtifactStore {
        return .{ .allocator = allocator, .io = io, .endpoint = endpoint };
    }
    pub fn head(self: ArtifactStore, key: Fingerprint, cancel: ?CancellationToken) !bool {
        const status = try self.request(.HEAD, key, null, null, cancel);
        return status == .ok;
    }
    pub fn put(self: ArtifactStore, key: Fingerprint, bytes: []const u8, cancel: ?CancellationToken) !void {
        var actual: Fingerprint = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &key, &actual)) return error.ChecksumMismatch;
        const status = try self.request(.PUT, key, bytes, null, cancel);
        if (status.class() != .success) return error.RemoteRejected;
    }
    pub fn get(self: ArtifactStore, key: Fingerprint, cancel: ?CancellationToken) !?Artifact {
        var writer: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer writer.deinit();
        const status = try self.request(.GET, key, null, &writer.writer, cancel);
        if (status == .not_found) {
            writer.deinit();
            return null;
        }
        if (status.class() != .success) return error.RemoteRejected;
        var list = writer.toArrayList();
        const bytes = list.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        var actual: Fingerprint = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &actual, .{});
        if (!std.mem.eql(u8, &key, &actual)) {
            self.allocator.free(bytes);
            return error.ChecksumMismatch;
        }
        return .{ .bytes = bytes, .digest = actual };
    }
    fn request(self: ArtifactStore, method: std.http.Method, key: Fingerprint, payload: ?[]const u8, response: ?*std.Io.Writer, cancel: ?CancellationToken) !std.http.Status {
        var url_buffer: [std.fs.max_path_bytes]u8 = undefined;
        var key_buffer: [64]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}/{s}", .{ self.endpoint, hex(key, &key_buffer) });
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            if (cancel) |token| if (token.isCancelled()) return error.Cancelled;
            var client: std.http.Client = .{ .allocator = self.allocator, .io = self.io };
            defer client.deinit();
            var headers: [1]std.http.Header = undefined;
            const header_slice: []const std.http.Header = if (self.authorization) |value| block: {
                headers[0] = .{ .name = "authorization", .value = value };
                break :block headers[0..];
            } else &.{};
            var discard: std.Io.Writer.Allocating = .init(self.allocator);
            defer discard.deinit();
            const fetched = client.fetch(.{ .location = .{ .url = url }, .method = method, .payload = payload, .response_writer = response orelse &discard.writer, .extra_headers = header_slice, .keep_alive = false }) catch |err| {
                if (attempt < self.retries) continue;
                return err;
            };
            if (fetched.status.class() == .server_error and attempt < self.retries) continue;
            return fetched.status;
        }
    }
};

/// Process-local bounded LRU cache. This is intentionally not a source of truth.
pub const L0 = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    used: usize = 0,
    tick: u64 = 0,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    const Entry = struct { key: Fingerprint, bytes: []u8, touch: u64 };
    pub fn init(allocator: std.mem.Allocator, capacity: usize) L0 {
        return .{ .allocator = allocator, .capacity = capacity };
    }
    pub fn deinit(self: *L0) void {
        for (self.entries.items) |entry| self.allocator.free(entry.bytes);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn get(self: *L0, key: Fingerprint) ?[]const u8 {
        for (self.entries.items) |*entry| if (std.mem.eql(u8, &entry.key, &key)) {
            self.tick +%= 1;
            entry.touch = self.tick;
            return entry.bytes;
        };
        return null;
    }
    pub fn put(self: *L0, key: Fingerprint, bytes: []const u8) !void {
        if (bytes.len > self.capacity) return;
        while (self.used + bytes.len > self.capacity and self.entries.items.len > 0) self.evictOldest();
        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        self.tick +%= 1;
        try self.entries.append(self.allocator, .{ .key = key, .bytes = owned, .touch = self.tick });
        self.used += bytes.len;
    }
    fn evictOldest(self: *L0) void {
        var oldest: usize = 0;
        for (self.entries.items[1..], 1..) |entry, i| {
            if (entry.touch < self.entries.items[oldest].touch) oldest = i;
        }
        const value = self.entries.swapRemove(oldest);
        self.used -= value.bytes.len;
        self.allocator.free(value.bytes);
    }
};

/// On-disk CAS used for project-local L1 and machine-shared L2 stores. Each entry has a
/// checksum-bearing manifest, staged writes, file sync, atomic publish, and quota GC.
pub const DiskCas = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    quota: usize,
    pub fn init(allocator: std.mem.Allocator, io: std.Io, directory: []const u8, quota: usize) DiskCas {
        return .{ .allocator = allocator, .io = io, .directory = directory, .quota = quota };
    }
    pub fn put(self: DiskCas, key: Fingerprint, bytes: []const u8) !void {
        try std.Io.Dir.cwd().createDirPath(self.io, self.directory);
        var name_buf: [64]u8 = undefined;
        const name = hex(key, &name_buf);
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const final_path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.directory, name });
        const existing = std.Io.Dir.cwd().openFile(self.io, final_path, .{}) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        if (existing) |file| {
            file.close(self.io);
            return;
        }
        var temp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const temp = try std.fmt.bufPrint(&temp_buf, "{s}/{s}.pending", .{ self.directory, name });
        var file = std.Io.Dir.cwd().createFile(self.io, temp, .{ .truncate = true, .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => {
                // Another process is publishing this key. Its successful atomic rename
                // is the merge point; do not duplicate the artifact.
                var spin: usize = 0;
                while (spin < 1024) : (spin += 1) {
                    if (std.Io.Dir.cwd().openFile(self.io, final_path, .{})) |published| {
                        published.close(self.io);
                        return;
                    } else |_| std.Thread.yield() catch {};
                }
                return error.ConcurrentPublishTimeout;
            },
            else => return err,
        };
        var header: [40]u8 = undefined;
        @memcpy(header[0..32], &key);
        std.mem.writeInt(u64, header[32..40], @intCast(bytes.len), .big);
        try file.writeStreamingAll(self.io, &header);
        try file.writeStreamingAll(self.io, bytes);
        try file.sync(self.io);
        file.close(self.io);
        std.Io.Dir.cwd().rename(temp, std.Io.Dir.cwd(), final_path, self.io) catch |err| switch (err) {
            error.PathAlreadyExists => std.Io.Dir.cwd().deleteFile(self.io, temp) catch {},
            else => return err,
        };
        try self.gc();
    }
    pub fn get(self: DiskCas, key: Fingerprint) !?Artifact {
        var name_buf: [64]u8 = undefined;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.directory, hex(key, &name_buf) });
        var buffer: [16 * 1024 * 1024]u8 = undefined;
        const all = std.Io.Dir.cwd().readFile(self.io, path, &buffer) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        if (all.len < 40 or !std.mem.eql(u8, all[0..32], &key) or std.mem.readInt(u64, all[32..40], .big) != all.len - 40) {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            return null;
        }
        var digest: Fingerprint = undefined;
        std.crypto.hash.sha2.Sha256.hash(all[40..], &digest, .{});
        if (!std.mem.eql(u8, &digest, &key)) {
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            return null;
        }
        return .{ .bytes = try self.allocator.dupe(u8, all[40..]), .digest = digest };
    }
    fn gc(self: DiskCas) !void {
        var dir = std.Io.Dir.cwd().openDir(self.io, self.directory, .{ .iterate = true }) catch return;
        defer dir.close(self.io);
        var iterator = std.Io.Dir.iterate(dir);
        var total: usize = 0;
        while (try iterator.next(self.io)) |entry| {
            if (std.mem.endsWith(u8, entry.name, ".pending")) std.Io.Dir.deleteFile(dir, self.io, entry.name) catch {} else if (entry.kind == .file) total += @intCast(entry.size);
        }
        while (total > self.quota) {
            iterator = std.Io.Dir.iterate(dir);
            var victim: [64]u8 = undefined;
            var victim_len: usize = 0;
            var victim_size: usize = 0;
            while (try iterator.next(self.io)) |entry| {
                if (entry.kind == .file and entry.name.len <= victim.len and !std.mem.endsWith(u8, entry.name, ".pending")) {
                    @memcpy(victim[0..entry.name.len], entry.name);
                    victim_len = entry.name.len;
                    victim_size = @intCast(entry.size);
                    break;
                }
            }
            if (victim_len == 0) break;
            try std.Io.Dir.deleteFile(dir, self.io, victim[0..victim_len]);
            total -= victim_size;
        }
    }
};

test "fingerprints are canonical and environment order is enforced" {
    const env = [_]Environment{ .{ .name = "A", .value = "1" }, .{ .name = "B", .value = "2" } };
    const a = try fingerprint(.{ .task_kind = "compile", .task_version = 1, .canonical_params = "{}", .input_versions = &.{2}, .input_hashes = &.{3}, .toolchain = "zig", .environment = &env });
    const b = try fingerprint(.{ .task_kind = "compile", .task_version = 1, .canonical_params = "{}", .input_versions = &.{2}, .input_hashes = &.{3}, .toolchain = "zig", .environment = &env });
    try std.testing.expectEqualSlices(u8, &a, &b);
    try std.testing.expectError(error.EnvironmentNotCanonical, fingerprint(.{ .task_kind = "compile", .task_version = 1, .canonical_params = "{}", .input_versions = &.{}, .input_hashes = &.{}, .toolchain = "zig", .environment = &.{ .{ .name = "B", .value = "2" }, .{ .name = "A", .value = "1" } } }));
}
