const std = @import("std");
const spindle = @import("spindle");
const login = @import("login_workflow");

const Ids = struct {
    value: u64 = 1,
    fn next(context: *anyopaque) spindle.core.StableId {
        const self: *Ids = @ptrCast(@alignCast(context));
        defer self.value += 1;
        return .{ .high = 21, .low = self.value };
    }
};

fn cleanup(path: []const u8) void {
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buffer: [256]u8 = undefined;
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const related = std.fmt.bufPrint(&buffer, "{s}{s}", .{ path, suffix }) catch continue;
        std.Io.Dir.cwd().deleteFile(io, related) catch {};
    }
}

test "verified local archive preserves hot history until manifest commit and composes after restart" {
    try std.testing.expect(@hasDecl(spindle.workflow.archive, "LocalArtifactStore"));
    try std.testing.expect(!@hasDecl(spindle.workflow.archive_http, "ArtifactStore"));
    const path = ".zig-cache/workflow-task21-archive.db";
    const directory = ".zig-cache/workflow-task21-archives";
    cleanup(path);
    std.Io.Dir.cwd().deleteTree(std.Options.debug_io, directory) catch {};
    defer cleanup(path);
    defer std.Io.Dir.cwd().deleteTree(std.Options.debug_io, directory) catch {};
    var clock = spindle.core.clock.VirtualClock.init(0, 5000);
    var ids: Ids = .{};
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock.clock());
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "archive" }, .tenant = "archive", .namespace = "test", .idempotency_key = "start", .utc_ms = 5000 });
    const artifacts = spindle.workflow.archive.LocalArtifactStore{ .io = std.Options.debug_io, .directory = directory };
    try std.testing.expectError(error.Conflict, spindle.workflow.archive.archiveCompleted(std.testing.allocator, &store, artifacts, "archive", "test", workflow_id, 5000));
    const hot = try store.readHistory(std.testing.allocator, "archive", "test", workflow_id);
    defer {
        for (hot) |record| std.testing.allocator.free(record.payload);
        std.testing.allocator.free(hot);
    }
    try std.testing.expectEqual(@as(usize, 1), hot.len);
    const mutation = spindle.workflow.sqlite.OperatorMutation{ .workflow_id = workflow_id, .tenant = "archive", .namespace = "test", .principal = "admin", .reason = "complete", .idempotency_key = "terminate", .authorized = true, .request_hash = 7 };
    try store.operatorTerminate(mutation, Ids.next(&ids));
    const before_manifest = try store.readHistory(std.testing.allocator, "archive", "test", workflow_id);
    defer {
        for (before_manifest) |record| std.testing.allocator.free(record.payload);
        std.testing.allocator.free(before_manifest);
    }
    const archive_records = try std.testing.allocator.alloc(spindle.workflow.archive.Record, before_manifest.len);
    defer std.testing.allocator.free(archive_records);
    for (before_manifest, 0..) |record, i| archive_records[i] = .{ .sequence = record.sequence, .kind = record.kind, .utc_ms = record.utc_ms, .schema = record.schema, .payload = record.payload };
    const staged_bytes = try spindle.workflow.archive.encode(std.testing.allocator, archive_records);
    defer std.testing.allocator.free(staged_bytes);
    var staged_name_buffer: [96]u8 = undefined;
    const staged_name = try std.fmt.bufPrint(&staged_name_buffer, "{x}-{x}-1-2.spar", .{ workflow_id.high, workflow_id.low });
    try artifacts.put(staged_name, staged_bytes);
    const still_hot = try store.readHistory(std.testing.allocator, "archive", "test", workflow_id);
    defer {
        for (still_hot) |record| std.testing.allocator.free(record.payload);
        std.testing.allocator.free(still_hot);
    }
    try std.testing.expectEqual(@as(usize, 2), still_hot.len);
    const manifest = try spindle.workflow.archive.archiveCompleted(std.testing.allocator, &store, artifacts, "archive", "test", workflow_id, 5000);
    try std.testing.expectEqual(@as(u64, 2), manifest.record_count);
    try std.testing.expectError(error.NotFound, store.readHistory(std.testing.allocator, "archive", "test", workflow_id));
    store.deinit();
    var reopened = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock.clock());
    defer reopened.deinit();
    const health = try reopened.health();
    try std.testing.expectEqual(@as(u64, 0), health.history_gaps);
    try std.testing.expectEqual(spindle.workflow.store_health.Integrity.healthy, health.integrity);
    const composed = try spindle.workflow.archive.readHistory(std.testing.allocator, &reopened, artifacts, "archive", "test", workflow_id, 16);
    defer spindle.workflow.archive.deinitRecords(std.testing.allocator, composed);
    try std.testing.expectEqual(@as(usize, 2), composed.len);
    try std.testing.expectEqual(spindle.workflow.event.Kind.started, composed[0].kind);
    try std.testing.expectEqual(spindle.workflow.event.Kind.workflow_terminated, composed[1].kind);
}
