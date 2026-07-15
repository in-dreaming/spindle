const std = @import("std");

pub const CommitPolicy = enum { atomic_replace, fail_on_conflict };
pub const CommitGroup = struct {
    expected_version: ?u64 = null,
    policy: CommitPolicy = .atomic_replace,
};

/// Filesystem-backed version store. Each payload is written before its `current` pointer.
/// The pointer contains a checksum, so recovery never accepts a torn or corrupt pointer.
pub const Store = struct {
    io: std.Io,
    directory: []const u8,

    pub fn init(io: std.Io, directory: []const u8) Store {
        return .{ .io = io, .directory = directory };
    }
    fn path(self: Store, buffer: []u8, suffix: []const u8) ![]u8 {
        return std.fmt.bufPrint(buffer, "{s}/{s}", .{ self.directory, suffix });
    }
    fn versionPath(self: Store, buffer: []u8, version: u64) ![]u8 {
        var suffix: [64]u8 = undefined;
        return self.path(buffer, try std.fmt.bufPrint(&suffix, "version-{d}", .{version}));
    }
    fn writeAndSync(self: Store, path_name: []const u8, data: []const u8, exclusive: bool) !void {
        var file = try std.Io.Dir.cwd().createFile(self.io, path_name, .{ .truncate = true, .exclusive = exclusive });
        defer file.close(self.io);
        try file.writeStreamingAll(self.io, data);
        try file.sync(self.io);
    }
    fn acquireLock(self: Store, path_name: []const u8) !void {
        var file = std.Io.Dir.cwd().createFile(self.io, path_name, .{ .exclusive = true }) catch |err| switch (err) {
            error.PathAlreadyExists => return error.Conflict,
            else => return err,
        };
        defer file.close(self.io);
        try file.sync(self.io);
    }
    fn validateRecord(self: Store, record: []const u8) !u64 {
        var parts = std.mem.tokenizeAny(u8, record, " \r\n\t");
        const version_text = parts.next() orelse return error.CorruptRecord;
        const hash_text = parts.next() orelse return error.CorruptRecord;
        const version = std.fmt.parseInt(u64, version_text, 10) catch return error.CorruptRecord;
        const expected = std.fmt.parseInt(u64, hash_text, 16) catch return error.CorruptRecord;
        var payload_path: [std.fs.max_path_bytes]u8 = undefined;
        const data_path = try self.versionPath(&payload_path, version);
        var data: [4096]u8 = undefined;
        const payload = try std.Io.Dir.cwd().readFile(self.io, data_path, &data);
        if (std.hash.Wyhash.hash(0, payload) != expected) return error.CorruptRecord;
        return version;
    }
    /// Prepares data, verifies its checksum, appends a checksum-bearing record, then atomically replaces `current`.
    pub fn commit(self: Store, group: CommitGroup, data: []const u8) !u64 {
        std.Io.Dir.cwd().createDirPath(self.io, self.directory) catch |err| if (err != error.PathAlreadyExists) return err;
        var lock_path: [std.fs.max_path_bytes]u8 = undefined;
        const lock = try self.path(&lock_path, "commit.lock");
        try self.acquireLock(lock);
        defer std.Io.Dir.cwd().deleteFile(self.io, lock) catch {};
        const previous = self.current() catch |err| if (err == error.FileNotFound) 0 else return err;
        if (group.expected_version) |expected| if (expected != previous) return error.Conflict;
        const next = previous + 1;
        var version_name: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&version_name, "version-{d}", .{next});
        var version_path: [std.fs.max_path_bytes]u8 = undefined;
        const full = try self.path(&version_path, name);
        if (group.policy == .fail_on_conflict) std.Io.Dir.cwd().openFile(self.io, full, .{}) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.Conflict,
        };
        try self.writeAndSync(full, data, group.policy == .fail_on_conflict);
        const checksum = std.hash.Wyhash.hash(0, data);
        var record: [96]u8 = undefined;
        const bytes = try std.fmt.bufPrint(&record, "{d} {x}\n", .{ next, checksum });
        var pending: [std.fs.max_path_bytes]u8 = undefined;
        const pending_path = try self.path(&pending, "current.pending");
        try self.writeAndSync(pending_path, bytes, false);
        var pointer: [std.fs.max_path_bytes]u8 = undefined;
        const pointer_path = try self.path(&pointer, "current");
        std.Io.Dir.cwd().rename(pending_path, std.Io.Dir.cwd(), pointer_path, self.io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                std.Io.Dir.cwd().deleteFile(self.io, pointer_path) catch {};
                try std.Io.Dir.cwd().rename(pending_path, std.Io.Dir.cwd(), pointer_path, self.io);
            },
            else => return err,
        };
        // Zig 0.16's portable std.Io has file sync but no directory-sync API. The
        // data and pointer records are fsynced; directory-entry durability is OS-specific.
        return next;
    }
    /// Reopens and validates the pointer against the referenced payload. Corrupt pointers fail closed.
    pub fn current(self: Store) !u64 {
        var pointer: [std.fs.max_path_bytes]u8 = undefined;
        const pointer_path = try self.path(&pointer, "current");
        var text: [128]u8 = undefined;
        const record = try std.Io.Dir.cwd().readFile(self.io, pointer_path, &text);
        return self.validateRecord(record);
    }
    /// Removes only version files that are not referenced by a validated current pointer.
    /// It never runs unless `current` has passed checksum validation.
    pub fn collectUnreachable(self: Store) !void {
        const current_version = try self.current();
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.directory, .{ .iterate = true });
        defer dir.close(self.io);
        var iterator = std.Io.Dir.iterate(dir);
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, "version-")) continue;
            const version = std.fmt.parseInt(u64, entry.name["version-".len..], 10) catch continue;
            if (version != current_version) try dir.deleteFile(self.io, entry.name);
        }
    }
    /// Repairs a fully written pointer that was not renamed, or removes a stale pending record.
    /// Repeated recovery is idempotent and never replaces an already valid current version.
    pub fn recover(self: Store) !void {
        var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const pending = try self.path(&path_buffer, "current.pending");
        var record_buffer: [128]u8 = undefined;
        const record = std.Io.Dir.cwd().readFile(self.io, pending, &record_buffer) catch |err| switch (err) {
            error.FileNotFound => {
                self.collectUnreachable() catch |current_err| if (current_err != error.FileNotFound) return current_err;
                return;
            },
            else => return err,
        };
        var pointer_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const pointer = try self.path(&pointer_buffer, "current");
        _ = self.current() catch |err| switch (err) {
            error.FileNotFound => {
                _ = self.validateRecord(record) catch |validation_err| {
                    std.Io.Dir.cwd().deleteFile(self.io, pending) catch {};
                    return validation_err;
                };
                try std.Io.Dir.cwd().rename(pending, std.Io.Dir.cwd(), pointer, self.io);
                try self.collectUnreachable();
                return;
            },
            else => return err,
        };
        try std.Io.Dir.cwd().deleteFile(self.io, pending);
        try self.collectUnreachable();
    }
};

test "commit store validates pointer payload and recovers pending records" {
    const directory = "spindle-task13-commit-test";
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const store = Store.init(io, directory);
    try std.testing.expectEqual(@as(u64, 1), try store.commit(.{}, "first"));
    try std.testing.expectEqual(@as(u64, 1), try store.current());
    try std.testing.expectError(error.Conflict, store.commit(.{ .expected_version = 0 }, "stale"));
    var pending: [std.fs.max_path_bytes]u8 = undefined;
    const pending_path = try store.path(&pending, "current.pending");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pending_path, .data = "interrupted" });
    try store.recover();
    try std.testing.expectEqual(@as(u64, 1), try store.current());
}

test "recovery promotes a synced record when pointer replacement was interrupted" {
    const directory = "spindle-task13-recovery-test";
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const store = Store.init(io, directory);
    _ = try store.commit(.{}, "first");
    var version: [std.fs.max_path_bytes]u8 = undefined;
    try store.writeAndSync(try store.versionPath(&version, 2), "second", false);
    var pending: [std.fs.max_path_bytes]u8 = undefined;
    var record: [96]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&record, "2 {x}\n", .{std.hash.Wyhash.hash(0, "second")});
    try store.writeAndSync(try store.path(&pending, "current.pending"), bytes, false);
    var current_path: [std.fs.max_path_bytes]u8 = undefined;
    try std.Io.Dir.cwd().deleteFile(io, try store.path(&current_path, "current"));
    try store.recover();
    try store.recover();
    try std.testing.expectEqual(@as(u64, 2), try store.current());
}

const ConcurrentCommit = struct {
    store: Store,
    succeeded: *std.atomic.Value(u32),
    fn run(self: @This()) void {
        _ = self.store.commit(.{ .expected_version = 0 }, "winner") catch return;
        _ = self.succeeded.fetchAdd(1, .acq_rel);
    }
};

test "concurrent expected-version commits have exactly one winner" {
    const directory = "spindle-task13-concurrency-test";
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var succeeded: std.atomic.Value(u32) = .init(0);
    const args = ConcurrentCommit{ .store = Store.init(io, directory), .succeeded = &succeeded };
    const first = try std.Thread.spawn(.{}, ConcurrentCommit.run, .{args});
    const second = try std.Thread.spawn(.{}, ConcurrentCommit.run, .{args});
    first.join();
    second.join();
    try std.testing.expectEqual(@as(u32, 1), succeeded.load(.acquire));
}

test "corrupt pointer fails closed without deleting the last payload" {
    const directory = "spindle-task13-corrupt-test";
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const store = Store.init(io, directory);
    _ = try store.commit(.{}, "durable-payload");
    var pointer: [std.fs.max_path_bytes]u8 = undefined;
    try store.writeAndSync(try store.path(&pointer, "current"), "not a record", false);
    try std.testing.expectError(error.CorruptRecord, store.recover());
    var payload: [std.fs.max_path_bytes]u8 = undefined;
    var data: [32]u8 = undefined;
    try std.testing.expectEqualStrings("durable-payload", try std.Io.Dir.cwd().readFile(io, try store.versionPath(&payload, 1), &data));
}

test "recovery garbage collects unreachable prepared versions only after validation" {
    const directory = "spindle-task13-gc-test";
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    const store = Store.init(io, directory);
    _ = try store.commit(.{}, "current");
    var orphan: [std.fs.max_path_bytes]u8 = undefined;
    try store.writeAndSync(try store.versionPath(&orphan, 2), "prepared-only", false);
    try store.recover();
    var data: [32]u8 = undefined;
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().readFile(io, try store.versionPath(&orphan, 2), &data));
    try std.testing.expectEqual(@as(u64, 1), try store.current());
}
