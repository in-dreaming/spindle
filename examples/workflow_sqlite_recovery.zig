const std = @import("std");
const spindle = @import("spindle");

const database_path = ".zig-cache/spindle-workflow-recovery-example.db";
const workflow_id = spindle.core.StableId{ .high = 1, .low = 1 };

pub fn main() !void {
    cleanup();
    defer cleanup();

    var clock = spindle.core.clock.VirtualClock.init(0, 1_000);
    var store = try spindle.workflow.sqlite.Store.init(std.heap.page_allocator, database_path, clock.clock());
    _ = try store.start(.{
        .workflow_id = workflow_id,
        .task_id = .{ .high = 1, .low = 2 },
        .event_id = .{ .high = 1, .low = 3 },
        .tenant = "example",
        .namespace = "recovery",
        .idempotency_key = "start-once",
        .request_hash = 1,
        .definition_id = 1,
        .definition_version = 1,
        .schema = .{ .id = 1, .version = 1 },
        .payload = "persist me",
        .utc_ms = clock.clock().utcNow(),
    });
    store.deinit();

    var reopened = try spindle.workflow.sqlite.Store.init(std.heap.page_allocator, database_path, clock.clock());
    defer reopened.deinit();
    const recovered = try reopened.getInstance("example", "recovery", workflow_id);
    defer std.heap.page_allocator.free(recovered.state);
    if (recovered.id.high != workflow_id.high or recovered.id.low != workflow_id.low) return error.RecoveryMismatch;
}

fn cleanup() void {
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteFile(io, database_path) catch {};
    std.Io.Dir.cwd().deleteFile(io, database_path ++ "-wal") catch {};
    std.Io.Dir.cwd().deleteFile(io, database_path ++ "-shm") catch {};
}
