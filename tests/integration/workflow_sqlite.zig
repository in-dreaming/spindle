const std = @import("std");
const spindle = @import("spindle");
const login = @import("login_workflow");
const build_options = @import("build_options");
const c = @cImport({
    @cInclude("sqlite3.h");
});

fn cleanup(path: []const u8) void {
    const io = std.Options.debug_io;
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
    var buffer: [256]u8 = undefined;
    const wal = std.fmt.bufPrint(&buffer, "{s}-wal", .{path}) catch return;
    std.Io.Dir.cwd().deleteFile(io, wal) catch {};
    const shm = std.fmt.bufPrint(&buffer, "{s}-shm", .{path}) catch return;
    std.Io.Dir.cwd().deleteFile(io, shm) catch {};
}

fn corruptMigrationChecksum(path: []const u8) !void {
    const zpath = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(zpath);
    var raw: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READWRITE, null) != c.SQLITE_OK) return error.DatabaseFailure;
    const db = raw orelse return error.DatabaseFailure;
    defer _ = c.sqlite3_close_v2(db);
    if (c.sqlite3_exec(db, "UPDATE spindle_schema_migration SET checksum=checksum+1 WHERE version=1;", null, null, null) != c.SQLITE_OK) return error.DatabaseFailure;
}

const Ids = struct {
    next_value: u64 = 1,
    fn next(p: *anyopaque) spindle.core.StableId {
        const self: *Ids = @ptrCast(@alignCast(p));
        defer self.next_value += 1;
        return .{ .high = 0, .low = self.next_value };
    }
};
test "sqlite migration idempotency and workflow start use a real file" {
    var clock_source = spindle.core.clock.VirtualClock.init(0, 100);
    const file = ".zig-cache/workflow-sqlite-integration.db";
    cleanup(file);
    defer cleanup(file);
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer store.deinit();
    try store.migrate();
    var ids: Ids = .{};
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const first = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "start" }, .tenant = "a", .namespace = "b", .idempotency_key = "same", .utc_ms = 100 });
    const second = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "start" }, .tenant = "a", .namespace = "b", .idempotency_key = "same", .utc_ms = 100 });
    try std.testing.expectEqual(first, second);
    try std.testing.expectError(error.IdempotencyConflict, client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "different" }, .tenant = "a", .namespace = "b", .idempotency_key = "same", .utc_ms = 100 }));
    const value = try client.getInstance("a", "b", first);
    defer std.testing.allocator.free(value.state);
    try std.testing.expectEqual(login.definition_id, value.definition_id);
}

test "sqlite migrations serialize and reject modified checksums" {
    const file = ".zig-cache/workflow-sqlite-migration.db";
    cleanup(file);
    defer cleanup(file);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 100);
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    var failures: std.atomic.Value(u32) = .init(0);
    const Probe = struct {
        fn run(target: *spindle.workflow.sqlite.Store, failed: *std.atomic.Value(u32)) void {
            target.migrate() catch {
                _ = failed.fetchAdd(1, .acq_rel);
            };
        }
    };
    const left = try std.Thread.spawn(.{}, Probe.run, .{ &store, &failures });
    const right = try std.Thread.spawn(.{}, Probe.run, .{ &store, &failures });
    left.join();
    right.join();
    try std.testing.expectEqual(@as(u32, 0), failures.load(.acquire));
    store.deinit();
    try corruptMigrationChecksum(file);
    try std.testing.expectError(error.MigrationMismatch, spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock()));
}

test "sqlite worker commits, deduplicates inbox, blocks versions, and fences restarts" {
    const file = ".zig-cache/workflow-sqlite-worker.db";
    cleanup(file);
    defer cleanup(file);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 200);
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    var store_open = true;
    defer if (store_open) store.deinit();
    try std.testing.expectError(error.WorkflowStoreInUse, spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock()));

    var ids: Ids = .{};
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "start" }, .tenant = "tenant", .namespace = "game", .idempotency_key = "worker", .utc_ms = 200 });
    var registry = spindle.workflow.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.register(login.definition);
    registry.freeze();
    const worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &registry, .tenant = "tenant", .namespace = "game" };
    try std.testing.expect(try worker.runOne());
    const value = try client.getInstance("tenant", "game", workflow_id);
    try std.testing.expectEqualStrings(login.waiting, value.state);
    std.testing.allocator.free(value.state);

    const message = spindle.core.StableId{ .high = 7, .low = 7 };
    const signal = spindle.workflow.client.SignalRequest{ .workflow_id = workflow_id, .signal_name = "reconnect", .payload = .{ .schema = login.event_schema, .bytes = "signal" }, .message_id = message, .tenant = "tenant", .namespace = "game", .utc_ms = 201 };
    try client.signal(signal);
    try client.signal(signal);
    try client.requestCancel(.{ .workflow_id = workflow_id, .message_id = .{ .high = 8, .low = 8 }, .tenant = "tenant", .namespace = "game", .utc_ms = 202 });
    try std.testing.expect(try worker.runOne());
    try std.testing.expect(!(try worker.runOne()));
    var runtime = spindle.workflow.sqlite_runtime.WorkflowRuntime.init(worker);
    defer runtime.deinit();
    try runtime.start();
    try runtime.shutdown(spindle.platform.park.deadlineAfter(std.time.ns_per_s));

    const denied = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.denyAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    try std.testing.expectError(error.Unauthorized, denied.getInstance("tenant", "game", workflow_id));
    const oversized = try std.testing.allocator.alloc(u8, spindle.workflow.sqlite.max_payload_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.PayloadTooLarge, client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = oversized }, .tenant = "tenant", .namespace = "game", .idempotency_key = "oversized", .utc_ms = 203 }));

    var unknown = login.definition;
    unknown.version = 99;
    _ = try client.start(.{ .definition_name = "game.login", .definition = unknown, .input = .{ .schema = login.event_schema, .bytes = "unknown" }, .tenant = "tenant", .namespace = "game", .idempotency_key = "unknown", .utc_ms = 203 });
    try std.testing.expectError(error.DefinitionUnavailable, worker.runOne());
    try std.testing.expectEqual(@as(usize, 1), try store.unblockDefinition(login.definition_id, 99));

    _ = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "reclaim" }, .tenant = "tenant", .namespace = "game", .idempotency_key = "reclaim", .utc_ms = 204 });
    const stale = (try store.claimWorkflowTask("tenant", "game")).?;
    store.deinit();
    store_open = false;
    var restarted = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer restarted.deinit();
    try std.testing.expectError(error.StaleRuntimeEpoch, restarted.commitWorkflowTaskTransition(.{ .claim = stale, .tenant = "tenant", .namespace = "game", .state = "bad", .status = .running, .last_processed_sequence = 1, .updated_utc_ms = 205 }));
    const reclaimed = (try restarted.claimWorkflowTask("tenant", "game")).?;
    try std.testing.expectEqual(stale.workflow_id, reclaimed.workflow_id);
    try std.testing.expect(reclaimed.runtime_epoch > stale.runtime_epoch);
}

test "real worker kill stages recover without duplicate transitions" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const process_io = threaded.io();
    inline for ([_][]const u8{ "after-claim", "before-commit", "after-commit" }) |stage| {
        var path_buffer: [128]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/workflow-crash-{s}.db", .{stage});
        cleanup(path);
        defer cleanup(path);
        var clock_source = spindle.core.clock.VirtualClock.init(0, 300);
        var ids: Ids = .{};
        var setup = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock_source.clock());
        const client = spindle.workflow.client.Client{ .store = &setup, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
        const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "crash" }, .tenant = "crash", .namespace = "test", .idempotency_key = stage, .utc_ms = 300 });
        setup.deinit();

        var child = try std.process.spawn(process_io, .{ .argv = &.{ build_options.crash_fixture, stage, path }, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
        var output_buffer: [16]u8 = undefined;
        var output_reader = child.stdout.?.readerStreaming(process_io, &output_buffer);
        const ready = output_reader.interface.takeArray(6) catch |err| {
            var error_reader = child.stderr.?.readerStreaming(process_io, &.{});
            const child_error = error_reader.interface.allocRemaining(std.testing.allocator, .limited(4096)) catch return err;
            defer std.testing.allocator.free(child_error);
            std.debug.print("workflow crash child ({s}): {s}\n", .{ stage, child_error });
            return err;
        };
        try std.testing.expectEqualStrings("READY\n", ready);
        child.kill(process_io);

        var recovered = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock_source.clock());
        defer recovered.deinit();
        var registry = spindle.workflow.Registry.init(std.testing.allocator);
        defer registry.deinit();
        try registry.register(login.definition);
        registry.freeze();
        const worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &recovered, .registry = &registry, .tenant = "crash", .namespace = "test" };
        if (std.mem.eql(u8, stage, "after-commit")) {
            try std.testing.expect(!(try worker.runOne()));
        } else {
            try std.testing.expect(try worker.runOne());
            try std.testing.expect(!(try worker.runOne()));
        }
        const value = try recovered.getInstance("crash", "test", workflow_id);
        defer std.testing.allocator.free(value.state);
        try std.testing.expectEqualStrings(login.waiting, value.state);
        try std.testing.expectEqual(@as(u64, 1), value.state_version);
    }
}
