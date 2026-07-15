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

const BusinessActivity = struct {
    const path = ".zig-cache/workflow-activity-business.db";
    var calls: std.atomic.Value(u32) = .init(0);
    fn reset() void {
        cleanup(path);
        calls.store(0, .release);
    }
    fn run(context: spindle.workflow.activity.Context, _: spindle.workflow.event.Payload) !spindle.workflow.activity.Result {
        _ = calls.fetchAdd(1, .acq_rel);
        const zpath = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(zpath);
        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE, null) != c.SQLITE_OK) return error.BusinessDatabaseFailure;
        const db = raw orelse return error.BusinessDatabaseFailure;
        defer _ = c.sqlite3_close_v2(db);
        if (c.sqlite3_exec(db, "CREATE TABLE IF NOT EXISTS activity_result(workflow_high INTEGER NOT NULL,workflow_low INTEGER NOT NULL,command_sequence INTEGER NOT NULL,result TEXT NOT NULL,PRIMARY KEY(workflow_high,workflow_low,command_sequence)) STRICT;", null, null, null) != c.SQLITE_OK) return error.BusinessDatabaseFailure;
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "INSERT OR IGNORE INTO activity_result VALUES(?1,?2,?3,'session-original');", -1, &statement, null) != c.SQLITE_OK) return error.BusinessDatabaseFailure;
        const insert = statement orelse return error.BusinessDatabaseFailure;
        defer _ = c.sqlite3_finalize(insert);
        _ = c.sqlite3_bind_int64(insert, 1, @bitCast(context.key.workflow_id.high));
        _ = c.sqlite3_bind_int64(insert, 2, @bitCast(context.key.workflow_id.low));
        _ = c.sqlite3_bind_int64(insert, 3, @intCast(context.key.command_sequence));
        if (c.sqlite3_step(insert) != c.SQLITE_DONE) return error.BusinessDatabaseFailure;
        return .{ .completed = .{ .schema = login.event_schema, .bytes = "session-original" } };
    }
    fn rowCount() !i64 {
        const zpath = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(zpath);
        var raw: ?*c.sqlite3 = null;
        if (c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) return error.BusinessDatabaseFailure;
        const db = raw orelse return error.BusinessDatabaseFailure;
        defer _ = c.sqlite3_close_v2(db);
        var statement: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db, "SELECT count(*) FROM activity_result;", -1, &statement, null) != c.SQLITE_OK) return error.BusinessDatabaseFailure;
        const query = statement orelse return error.BusinessDatabaseFailure;
        defer _ = c.sqlite3_finalize(query);
        if (c.sqlite3_step(query) != c.SQLITE_ROW) return error.BusinessDatabaseFailure;
        return c.sqlite3_column_int64(query, 0);
    }
};

fn registerLogin(registry: *spindle.workflow.Registry) !void {
    try registry.register(login.definition);
    registry.freeze();
}
fn registerBusiness(registry: *spindle.workflow.activity.Registry) !void {
    try registry.register(.{ .stable_name = "authenticate", .type_id = 0x6175_7468, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "login", .idempotency = .required, .executor = .blocking, .retry_policy = .{ .initial_backoff_ms = 5, .max_backoff_ms = 20, .max_attempts = 3 }, .handler = BusinessActivity.run });
    registry.freeze();
}

const ProbeActivity = struct {
    const Mode = enum { complete, transient, always_transient, permanent, start_timeout, heartbeat_timeout, wait_cancel };
    var mode: Mode = .complete;
    var clock: ?*spindle.core.clock.VirtualClock = null;
    var calls: std.atomic.Value(u32) = .init(0);
    var started: std.atomic.Value(bool) = .init(false);
    fn reset(value: Mode, source: *spindle.core.clock.VirtualClock) void {
        mode = value;
        clock = source;
        calls.store(0, .release);
        started.store(false, .release);
    }
    fn run(context: spindle.workflow.activity.Context, _: spindle.workflow.event.Payload) !spindle.workflow.activity.Result {
        _ = calls.fetchAdd(1, .acq_rel);
        return switch (mode) {
            .complete => .{ .completed = .{ .schema = login.event_schema, .bytes = "ok" } },
            .transient => if (context.attempt < 3) .{ .failed = .{ .kind = .application, .code = 7, .message = "transient" } } else .{ .completed = .{ .schema = login.event_schema, .bytes = "ok" } },
            .always_transient => .{ .failed = .{ .kind = .application, .code = 7, .message = "transient" } },
            .permanent => .{ .failed = .{ .kind = .application, .code = 42, .message = "permanent" } },
            .start_timeout => blk: {
                started.store(true, .release);
                clock.?.advance(0, 10);
                while (!context.cancellation.isCancelled()) std.Thread.yield() catch {};
                break :blk .{ .completed = .{ .schema = login.event_schema, .bytes = "late" } };
            },
            .heartbeat_timeout => blk: {
                started.store(true, .release);
                try context.heartbeat.beat();
                clock.?.advance(0, 3);
                try context.heartbeat.beat();
                clock.?.advance(0, 6);
                while (!context.cancellation.isCancelled()) std.Thread.yield() catch {};
                break :blk .{ .completed = .{ .schema = login.event_schema, .bytes = "late" } };
            },
            .wait_cancel => blk: {
                started.store(true, .release);
                while (!context.cancellation.isCancelled()) std.Thread.yield() catch {};
                break :blk .{ .failed = .{ .kind = .cancelled, .code = 1004, .message = "cancelled" } };
            },
        };
    }
};

const ShutdownActivity = struct {
    var started: std.atomic.Value(bool) = .init(false);
    var release: std.atomic.Value(bool) = .init(false);
    fn reset() void {
        started.store(false, .release);
        release.store(false, .release);
    }
    fn run(_: spindle.workflow.activity.Context, _: spindle.workflow.event.Payload) !spindle.workflow.activity.Result {
        started.store(true, .release);
        while (!release.load(.acquire)) std.Thread.yield() catch {};
        return .{ .completed = .{ .schema = login.event_schema, .bytes = "released" } };
    }
};

fn discardTransport(_: ?*anyopaque, _: spindle.core.StableId, _: []const u8) !void {}

fn runActivityFailureScenario(name: []const u8, mode: ProbeActivity.Mode, timeouts: spindle.workflow.activity.Timeout, pre_advance_ms: i64) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/workflow-timeout-{s}.db", .{name});
    cleanup(path);
    defer cleanup(path);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 1100);
    ProbeActivity.reset(mode, &clock_source);
    var ids: Ids = .{};
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock_source.clock());
    defer store.deinit();
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "timeout" }, .tenant = "timeout", .namespace = name, .idempotency_key = name, .utc_ms = 1100 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try registerLogin(&workflows);
    const workflow_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &workflows, .tenant = "timeout", .namespace = name };
    try std.testing.expect(try workflow_worker.runOne());
    clock_source.advance(0, pre_advance_ms);
    var activities = spindle.workflow.activity.Registry.init(std.testing.allocator);
    defer activities.deinit();
    const retry_policy: spindle.workflow.activity.RetryPolicy = switch (mode) {
        .permanent => .{ .initial_backoff_ms = 5, .max_backoff_ms = 20, .max_attempts = 3, .non_retryable = &.{42} },
        .always_transient => .{ .initial_backoff_ms = 5, .max_backoff_ms = 20, .max_attempts = 3 },
        else => .{ .initial_backoff_ms = 0, .max_backoff_ms = 0, .max_attempts = 1 },
    };
    try activities.register(.{ .stable_name = "authenticate", .type_id = 90, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "test", .idempotency = .required, .executor = .blocking, .timeouts = timeouts, .retry_policy = retry_policy, .handler = ProbeActivity.run });
    activities.freeze();
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 8);
    defer compute.deinit();
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 8);
    defer blocking.deinit();
    const activity_worker = spindle.workflow.activity_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &activities, .tenant = "timeout", .namespace = name, .compute = compute.executor(), .blocking = blocking.executor() };
    try std.testing.expect(try activity_worker.runOne());
    if (mode == .always_transient) {
        clock_source.advance(0, 5);
        try std.testing.expect(try activity_worker.runOne());
        clock_source.advance(0, 10);
        try std.testing.expect(try activity_worker.runOne());
    }
    try std.testing.expect(try workflow_worker.runOne());
    const value = try store.getInstance("timeout", name, workflow_id);
    defer std.testing.allocator.free(value.state);
    try std.testing.expectEqualStrings(login.timed_out, value.state);
}
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

test "registered idempotent activity is delivered through an executor and wakes login workflow" {
    const file = ".zig-cache/workflow-sqlite-activity.db";
    cleanup(file);
    defer cleanup(file);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 500);
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer store.deinit();
    var ids: Ids = .{};
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "start" }, .tenant = "activity", .namespace = "test", .idempotency_key = "activity", .utc_ms = 500 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try workflows.register(login.definition);
    workflows.freeze();
    const workflow_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &workflows, .tenant = "activity", .namespace = "test" };
    try std.testing.expect(try workflow_worker.runOne());

    var activities = spindle.workflow.activity.Registry.init(std.testing.allocator);
    defer activities.deinit();
    const Handler = struct {
        fn run(_: spindle.workflow.activity.Context, _: spindle.workflow.event.Payload) !spindle.workflow.activity.Result {
            return .{ .completed = .{ .schema = login.event_schema, .bytes = "ok" } };
        }
    };
    try std.testing.expectError(error.IdempotencyContractRequired, activities.register(.{ .stable_name = "reject", .type_id = 1, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "test", .idempotency = .test_only, .executor = .blocking, .handler = Handler.run }));
    try activities.register(.{ .stable_name = "authenticate", .type_id = 2, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "test", .idempotency = .required, .executor = .blocking, .handler = Handler.run });
    activities.freeze();
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 8);
    defer compute.deinit();
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 8);
    defer blocking.deinit();
    const activity_worker = spindle.workflow.activity_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &activities, .tenant = "activity", .namespace = "test", .compute = compute.executor(), .blocking = blocking.executor() };
    try std.testing.expect(try activity_worker.runOne());
    try std.testing.expect(try workflow_worker.runOne());
    const value = try client.getInstance("activity", "test", workflow_id);
    defer std.testing.allocator.free(value.state);
    try std.testing.expectEqualStrings(login.authenticated, value.state);
}

test "activity duplicate after side effect is idempotent and stale completion is fenced" {
    const file = ".zig-cache/workflow-activity-duplicate.db";
    cleanup(file);
    defer cleanup(file);
    BusinessActivity.reset();
    defer cleanup(BusinessActivity.path);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 700);
    var ids: Ids = .{};
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "start" }, .tenant = "dup", .namespace = "test", .idempotency_key = "dup", .utc_ms = 700 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try registerLogin(&workflows);
    const workflow_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &workflows, .tenant = "dup", .namespace = "test" };
    try std.testing.expect(try workflow_worker.runOne());
    const stale = (try store.claimActivity(std.testing.allocator, "dup", "test")).?;
    var source = spindle.executor.CancellationSource{};
    _ = try BusinessActivity.run(.{ .key = .{ .workflow_id = stale.workflow_id, .command_sequence = stale.command_sequence }, .attempt = stale.attempt, .deadline_utc_ms = null, .cancellation = source.token(), .trace = .{}, .heartbeat = .{} }, .{ .schema = stale.schema, .bytes = stale.payload });
    store.deinit();
    var restarted = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer restarted.deinit();
    try std.testing.expectError(error.StaleRuntimeEpoch, restarted.finishActivity(stale, "dup", "test", spindle.workflow.event.Kind.activity_completed, login.event_schema, "stale"));
    var activities = spindle.workflow.activity.Registry.init(std.testing.allocator);
    defer activities.deinit();
    try registerBusiness(&activities);
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 8);
    defer compute.deinit();
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 8);
    defer blocking.deinit();
    const activity_worker = spindle.workflow.activity_worker.Worker{ .allocator = std.testing.allocator, .store = &restarted, .registry = &activities, .tenant = "dup", .namespace = "test", .compute = compute.executor(), .blocking = blocking.executor() };
    try std.testing.expect(try activity_worker.runOne());
    const recovered_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &restarted, .registry = &workflows, .tenant = "dup", .namespace = "test" };
    try std.testing.expect(try recovered_worker.runOne());
    const value = try restarted.getInstance("dup", "test", workflow_id);
    defer std.testing.allocator.free(value.state);
    try std.testing.expectEqualStrings(login.authenticated, value.state);
    try std.testing.expectEqual(@as(i64, 1), try BusinessActivity.rowCount());
    try std.testing.expectEqual(@as(u32, 2), BusinessActivity.calls.load(.acquire));
}

test "timer outbox and inbox survive restart with send-before-mark duplication" {
    const sender_path = ".zig-cache/workflow-messaging-sender.db";
    const receiver_path = ".zig-cache/workflow-messaging-receiver.db";
    cleanup(sender_path);
    cleanup(receiver_path);
    defer cleanup(sender_path);
    defer cleanup(receiver_path);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 900);
    var sender_ids: Ids = .{};
    var receiver_ids: Ids = .{ .next_value = 100 };
    var receiver = try spindle.workflow.sqlite.Store.init(std.testing.allocator, receiver_path, clock_source.clock());
    var receiver_open = true;
    defer if (receiver_open) receiver.deinit();
    const receiver_client = spindle.workflow.client.Client{ .store = &receiver, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &receiver_ids, .next_fn = Ids.next } };
    const receiver_id = try receiver_client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "receiver" }, .tenant = "loop", .namespace = "test", .idempotency_key = "receiver", .utc_ms = 900 });
    var sender = try spindle.workflow.sqlite.Store.init(std.testing.allocator, sender_path, clock_source.clock());
    const sender_client = spindle.workflow.client.Client{ .store = &sender, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &sender_ids, .next_fn = Ids.next } };
    _ = try sender_client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "sender" }, .tenant = "send", .namespace = "test", .idempotency_key = "sender", .utc_ms = 900 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try registerLogin(&workflows);
    const sender_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &sender, .registry = &workflows, .tenant = "send", .namespace = "test" };
    try std.testing.expect(try sender_worker.runOne());
    try std.testing.expect((try sender.claimTimer(std.testing.allocator, "send", "test")) == null);
    var loopback = spindle.workflow.outbox.Loopback{ .store = &receiver, .tenant = "loop", .namespace = "test", .workflow_id = receiver_id, .schema = login.event_schema };
    const stale_outbox = (try sender.claimOutbox(std.testing.allocator, "send", "test")).?;
    try loopback.transport().publish(stale_outbox.message_id, stale_outbox.payload);
    sender.deinit();
    var restarted = try spindle.workflow.sqlite.Store.init(std.testing.allocator, sender_path, clock_source.clock());
    try std.testing.expectError(error.StaleRuntimeEpoch, restarted.finishOutbox(stale_outbox));
    const publisher = spindle.workflow.outbox.Publisher{ .allocator = std.testing.allocator, .store = &restarted, .tenant = "send", .namespace = "test", .transport = loopback.transport() };
    try std.testing.expect(try publisher.runOne());
    try std.testing.expect(!(try publisher.runOne()));
    clock_source.advance(0, -50);
    try std.testing.expect((try restarted.claimTimer(std.testing.allocator, "send", "test")) == null);
    clock_source.advance(0, 150);
    const stale_timer = (try restarted.claimTimer(std.testing.allocator, "send", "test")).?;
    restarted.deinit();
    var after_timer_restart = try spindle.workflow.sqlite.Store.init(std.testing.allocator, sender_path, clock_source.clock());
    defer after_timer_restart.deinit();
    try std.testing.expectError(error.StaleRuntimeEpoch, after_timer_restart.fireTimer(stale_timer, "send", "test", stale_timer.schema));
    const timer_worker = spindle.workflow.timer_worker.Worker{ .allocator = std.testing.allocator, .store = &after_timer_restart, .tenant = "send", .namespace = "test" };
    try std.testing.expect(try timer_worker.runOne());
    try std.testing.expect(!(try timer_worker.runOne()));
    receiver.deinit();
    receiver_open = false;
    var receiver_restart = try spindle.workflow.sqlite.Store.init(std.testing.allocator, receiver_path, clock_source.clock());
    defer receiver_restart.deinit();
    const receiver_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &receiver_restart, .registry = &workflows, .tenant = "loop", .namespace = "test" };
    try std.testing.expect(try receiver_worker.runOne());
    try std.testing.expect(!(try receiver_worker.runOne()));
}

test "activity retries are deterministic and non-retryable failures exhaust immediately" {
    const file = ".zig-cache/workflow-activity-retry.db";
    cleanup(file);
    defer cleanup(file);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 1000);
    ProbeActivity.reset(.transient, &clock_source);
    var ids: Ids = .{};
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer store.deinit();
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "retry" }, .tenant = "retry", .namespace = "test", .idempotency_key = "retry", .utc_ms = 1000 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try registerLogin(&workflows);
    const workflow_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &workflows, .tenant = "retry", .namespace = "test" };
    try std.testing.expect(try workflow_worker.runOne());
    var activities = spindle.workflow.activity.Registry.init(std.testing.allocator);
    defer activities.deinit();
    try activities.register(.{ .stable_name = "authenticate", .type_id = 91, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "test", .idempotency = .required, .executor = .compute, .retry_policy = .{ .initial_backoff_ms = 5, .max_backoff_ms = 20, .max_attempts = 3 }, .handler = ProbeActivity.run });
    activities.freeze();
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 8);
    defer compute.deinit();
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 8);
    defer blocking.deinit();
    const activity_worker = spindle.workflow.activity_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &activities, .tenant = "retry", .namespace = "test", .compute = compute.executor(), .blocking = blocking.executor() };
    try std.testing.expect(try activity_worker.runOne());
    try std.testing.expect(!(try activity_worker.runOne()));
    clock_source.advance(0, 5);
    try std.testing.expect(try activity_worker.runOne());
    clock_source.advance(0, 10);
    try std.testing.expect(try activity_worker.runOne());
    try std.testing.expectEqual(@as(u32, 3), ProbeActivity.calls.load(.acquire));
    try std.testing.expect(try workflow_worker.runOne());
    const value = try store.getInstance("retry", "test", workflow_id);
    defer std.testing.allocator.free(value.state);
    try std.testing.expectEqualStrings(login.authenticated, value.state);

    try runActivityFailureScenario("permanent", .permanent, .{}, 0);
    try std.testing.expectEqual(@as(u32, 1), ProbeActivity.calls.load(.acquire));
    try runActivityFailureScenario("exhausted", .always_transient, .{}, 0);
    try std.testing.expectEqual(@as(u32, 3), ProbeActivity.calls.load(.acquire));
}

test "all activity timeout classes and cancellation race record terminal failure" {
    try runActivityFailureScenario("schedule", .complete, .{ .schedule_to_start_ms = 5 }, 5);
    try std.testing.expectEqual(@as(u32, 0), ProbeActivity.calls.load(.acquire));
    try runActivityFailureScenario("start", .start_timeout, .{ .start_to_close_ms = 5 }, 0);
    try runActivityFailureScenario("heartbeat", .heartbeat_timeout, .{ .heartbeat_ms = 5 }, 0);

    const file = ".zig-cache/workflow-activity-cancel.db";
    cleanup(file);
    defer cleanup(file);
    var clock_source = spindle.core.clock.VirtualClock.init(0, 1200);
    ProbeActivity.reset(.wait_cancel, &clock_source);
    var ids: Ids = .{};
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer store.deinit();
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    const workflow_id = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "cancel" }, .tenant = "cancel", .namespace = "test", .idempotency_key = "cancel", .utc_ms = 1200 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try registerLogin(&workflows);
    const workflow_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &workflows, .tenant = "cancel", .namespace = "test" };
    try std.testing.expect(try workflow_worker.runOne());
    var activities = spindle.workflow.activity.Registry.init(std.testing.allocator);
    defer activities.deinit();
    try activities.register(.{ .stable_name = "authenticate", .type_id = 92, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "test", .idempotency = .required, .executor = .blocking, .handler = ProbeActivity.run });
    activities.freeze();
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 8);
    defer compute.deinit();
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 8);
    defer blocking.deinit();
    var activity_worker = spindle.workflow.activity_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &activities, .tenant = "cancel", .namespace = "test", .compute = compute.executor(), .blocking = blocking.executor() };
    const Runner = struct {
        fn run(worker: *spindle.workflow.activity_worker.Worker, failed: *std.atomic.Value(bool)) void {
            _ = worker.runOne() catch {
                failed.store(true, .release);
            };
        }
    };
    var failed: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Runner.run, .{ &activity_worker, &failed });
    while (!ProbeActivity.started.load(.acquire)) std.Thread.yield() catch {};
    try client.requestCancel(.{ .workflow_id = workflow_id, .message_id = .{ .high = 44, .low = 44 }, .tenant = "cancel", .namespace = "test", .utc_ms = 1200 });
    thread.join();
    try std.testing.expect(!failed.load(.acquire));
    try std.testing.expect(try workflow_worker.runOne());
    const value = try store.getInstance("cancel", "test", workflow_id);
    defer std.testing.allocator.free(value.state);
    try std.testing.expectEqualStrings(login.timed_out, value.state);
}

test "workflow subsystem joins workers and honors shutdown deadline for long activity" {
    const file = ".zig-cache/workflow-subsystem.db";
    cleanup(file);
    defer cleanup(file);
    ShutdownActivity.reset();
    var clock_source = spindle.core.clock.VirtualClock.init(0, 1300);
    var ids: Ids = .{};
    var store = try spindle.workflow.sqlite.Store.init(std.testing.allocator, file, clock_source.clock());
    defer store.deinit();
    const client = spindle.workflow.client.Client{ .store = &store, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
    _ = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "shutdown" }, .tenant = "shutdown", .namespace = "test", .idempotency_key = "shutdown", .utc_ms = 1300 });
    var workflows = spindle.workflow.Registry.init(std.testing.allocator);
    defer workflows.deinit();
    try registerLogin(&workflows);
    var activities = spindle.workflow.activity.Registry.init(std.testing.allocator);
    defer activities.deinit();
    try activities.register(.{ .stable_name = "authenticate", .type_id = 93, .input_schema = login.command_schema, .output_schema = login.event_schema, .ownership = "test", .idempotency = .required, .executor = .blocking, .handler = ShutdownActivity.run });
    activities.freeze();
    var compute = try spindle.executor.FixedPool.init(std.testing.allocator, 1, 8);
    defer compute.deinit();
    var blocking = try spindle.executor.BlockingExecutor.init(std.testing.allocator, 1, 8);
    defer blocking.deinit();
    const workflow_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &workflows, .tenant = "shutdown", .namespace = "test" };
    const activity_worker = spindle.workflow.activity_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .registry = &activities, .tenant = "shutdown", .namespace = "test", .compute = compute.executor(), .blocking = blocking.executor() };
    const timer_worker = spindle.workflow.timer_worker.Worker{ .allocator = std.testing.allocator, .store = &store, .tenant = "shutdown", .namespace = "test" };
    const publisher = spindle.workflow.outbox.Publisher{ .allocator = std.testing.allocator, .store = &store, .tenant = "shutdown", .namespace = "test", .transport = .{ .context = null, .publish_fn = discardTransport } };
    var subsystem = spindle.workflow.sqlite_runtime.WorkflowSubsystem.init(workflow_worker, activity_worker, timer_worker, publisher);
    defer subsystem.deinit();
    try subsystem.start();
    while (!ShutdownActivity.started.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectError(error.Timeout, subsystem.shutdown(spindle.platform.park.deadlineAfter(0)));
    ShutdownActivity.release.store(true, .release);
    try subsystem.shutdown(spindle.platform.park.deadlineAfter(std.time.ns_per_s));
}

test "real subprocess activity timer and outbox crash stages recover" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const process_io = threaded.io();
    inline for ([_][]const u8{ "activity-after-side-effect", "activity-before-result-commit", "activity-after-result-commit", "timer-after-claim", "outbox-after-send" }) |stage| {
        var path_buffer: [160]u8 = undefined;
        const path = try std.fmt.bufPrint(&path_buffer, ".zig-cache/workflow-task18-crash-{s}.db", .{stage});
        cleanup(path);
        defer cleanup(path);
        var marker_buffer: [256]u8 = undefined;
        const marker = try std.fmt.bufPrint(&marker_buffer, "{s}.{s}.effect", .{ path, stage });
        cleanup(marker);
        defer cleanup(marker);
        var clock_source = spindle.core.clock.VirtualClock.init(0, 300);
        var ids: Ids = .{};
        var setup = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock_source.clock());
        const client = spindle.workflow.client.Client{ .store = &setup, .auth_context = null, .auth = spindle.workflow.client.allowAll, .ids = .{ .context = &ids, .next_fn = Ids.next } };
        _ = try client.start(.{ .definition_name = "game.login", .definition = login.definition, .input = .{ .schema = login.event_schema, .bytes = "crash18" }, .tenant = "crash", .namespace = "test", .idempotency_key = stage, .utc_ms = 300 });
        var workflows = spindle.workflow.Registry.init(std.testing.allocator);
        defer workflows.deinit();
        try registerLogin(&workflows);
        const setup_worker = spindle.workflow.sqlite_worker.Worker{ .allocator = std.testing.allocator, .store = &setup, .registry = &workflows, .tenant = "crash", .namespace = "test" };
        try std.testing.expect(try setup_worker.runOne());
        setup.deinit();
        var child = try std.process.spawn(process_io, .{ .argv = &.{ build_options.crash_fixture, stage, path }, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
        var output_buffer: [16]u8 = undefined;
        var output_reader = child.stdout.?.readerStreaming(process_io, &output_buffer);
        const ready = try output_reader.interface.takeArray(6);
        try std.testing.expectEqualStrings("READY\n", ready);
        child.kill(process_io);
        var recovered = try spindle.workflow.sqlite.Store.init(std.testing.allocator, path, clock_source.clock());
        defer recovered.deinit();
        if (std.mem.startsWith(u8, stage, "activity-")) {
            if (std.mem.eql(u8, stage, "activity-after-result-commit")) try std.testing.expect((try recovered.claimActivity(std.testing.allocator, "crash", "test")) == null) else {
                const claim = (try recovered.claimActivity(std.testing.allocator, "crash", "test")).?;
                try recovered.finishActivity(claim, "crash", "test", spindle.workflow.event.Kind.activity_completed, login.event_schema, "recovered");
            }
        } else if (std.mem.eql(u8, stage, "timer-after-claim")) {
            try std.testing.expect((try recovered.claimTimer(std.testing.allocator, "crash", "test")) == null);
            clock_source.advance(0, 100);
            const claim = (try recovered.claimTimer(std.testing.allocator, "crash", "test")).?;
            try recovered.fireTimer(claim, "crash", "test", claim.schema);
        } else {
            const claim = (try recovered.claimOutbox(std.testing.allocator, "crash", "test")).?;
            try recovered.finishOutbox(claim);
        }
    }
}
