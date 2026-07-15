const std = @import("std");
const core = @import("../core/root.zig");
const executor = @import("../executor/root.zig");
const event = @import("event.zig");
const instance = @import("instance.zig");
const persistence = @import("persistence.zig");
const snapshot = @import("snapshot.zig");
const store_health = @import("store_health.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const sqlite_transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

pub const max_payload_bytes: usize = 1024 * 1024;
pub const Error = error{ WorkflowStoreInUse, MigrationMismatch, CorruptSchema, PayloadTooLarge, IdempotencyConflict, NotFound, StaleRuntimeEpoch, Conflict, DatabaseBusy, DatabaseFull, DatabaseIo, DatabaseReadOnly, DatabaseFailure, BackupInterrupted, MaintenanceCancelled, RestoreFailed };
pub const InstanceRecord = struct { id: core.StableId, definition_id: u64, definition_version: u32, status: instance.Status, state_version: u64, state: []u8 };
pub const Claim = struct { task_id: core.StableId, workflow_id: core.StableId, state_version: u64, definition_id: u64, definition_version: u32, runtime_epoch: u64 };
pub const ActivityClaim = struct { allocator: std.mem.Allocator, task_id: core.StableId, workflow_id: core.StableId, command_sequence: u64, attempt: u32, runtime_epoch: u64, scheduled_utc_ms: i64, started_utc_ms: i64, payload: []u8, schema: core.schema.SchemaKey };
pub const TimerClaim = struct { allocator: std.mem.Allocator, timer_id: core.StableId, workflow_id: core.StableId, runtime_epoch: u64, payload: []u8, schema: core.schema.SchemaKey };
pub const OutboxClaim = struct { allocator: std.mem.Allocator, message_id: core.StableId, workflow_id: core.StableId, runtime_epoch: u64, payload: []u8 };
pub const LoadedTask = struct {
    allocator: std.mem.Allocator,
    claim: Claim,
    tenant: []u8,
    namespace: []u8,
    state: []u8,
    last_processed_sequence: u64,
    events: []event.Event,
    pub fn deinit(self: *LoadedTask) void {
        for (self.events) |value| self.allocator.free(value.payload.bytes);
        self.allocator.free(self.events);
        self.allocator.free(self.state);
        self.allocator.free(self.tenant);
        self.allocator.free(self.namespace);
        self.* = undefined;
    }
};
pub const Commit = struct {
    claim: Claim,
    tenant: []const u8,
    namespace: []const u8,
    state: []const u8,
    status: instance.Status,
    last_processed_sequence: u64,
    optional_snapshot: ?snapshot.Snapshot = null,
    scheduled: persistence.ScheduledWork = .{},
    updated_utc_ms: i64,
};
const migration_sql = @import("workflow_sqlite_migrations").workflow_sqlite_v1;
const migration_v2_sql = @import("workflow_sqlite_migrations").workflow_sqlite_v2;
const migration_v3_sql = @import("workflow_sqlite_migrations").workflow_sqlite_v3;

/// One SQLite connection, serialized by this store. It owns the process-local SQLite store lock.
pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    db: *c.sqlite3,
    clock: core.Clock,
    mutex: std.atomic.Mutex = .unlocked,
    runtime_epoch: u64,
    dispatcher: executor.BlockingExecutor,
    previous_shutdown_clean: bool = false,
    recovery: store_health.Recovery = .{},
    clean_shutdown_written: bool = false,
    initialized: bool = false,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, clock: core.Clock) Error!Store {
        const owned_path = allocator.dupe(u8, path) catch return error.DatabaseFailure;
        errdefer allocator.free(owned_path);
        const zpath = allocator.dupeZ(u8, path) catch return error.DatabaseFailure;
        defer allocator.free(zpath);
        var raw: ?*c.sqlite3 = null;
        const open_result = c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (open_result != c.SQLITE_OK) {
            if (raw) |handle| _ = c.sqlite3_close_v2(handle);
            return map(open_result);
        }
        const db = raw orelse return error.DatabaseFailure;
        const dispatcher = executor.BlockingExecutor.init(allocator, 1, 128) catch {
            _ = c.sqlite3_close_v2(db);
            return error.DatabaseFailure;
        };
        var self = Store{ .allocator = allocator, .path = &.{}, .db = db, .clock = clock, .runtime_epoch = 0, .dispatcher = dispatcher };
        errdefer self.deinit();
        try self.invoke(Store.initialize, .{});
        self.path = owned_path;
        self.initialized = true;
        return self;
    }

    fn initialize(self: *Store) Error!void {
        self.exec("PRAGMA journal_mode=WAL;") catch |err| return initError(err);
        self.exec("PRAGMA foreign_keys=ON;") catch |err| return initError(err);
        self.exec("PRAGMA synchronous=FULL;") catch |err| return initError(err);
        self.exec("PRAGMA busy_timeout=0;") catch |err| return initError(err);
        // An exclusive locking-mode connection remains the sole active runtime for this file.
        self.exec("PRAGMA locking_mode=EXCLUSIVE;") catch |err| return initError(err);
        self.beginExclusive() catch |err| return if (err == error.DatabaseBusy) error.WorkflowStoreInUse else err;
        errdefer self.rollback();
        self.applyMigration() catch |err| return if (err == error.DatabaseBusy) error.WorkflowStoreInUse else err;
        self.previous_shutdown_clean = (try self.metadataU64("clean_shutdown")) != 0;
        const previous = try self.metadataU64("runtime_epoch");
        self.runtime_epoch = previous + 1;
        try self.setMetadataU64("runtime_epoch", self.runtime_epoch);
        try self.setMetadataU64("clean_shutdown", 0);
        self.recovery = try self.recoverClaims();
        try self.commit();
    }

    pub fn deinit(self: *Store) void {
        self.invoke(Store.close, .{}) catch {};
        self.dispatcher.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }
    fn close(self: *Store) Error!void {
        if (self.initialized and !self.clean_shutdown_written) self.markCleanShutdown() catch {};
        if (c.sqlite3_close_v2(self.db) != c.SQLITE_OK) return error.DatabaseFailure;
    }
    fn markCleanShutdown(self: *Store) Error!void {
        try self.begin();
        errdefer self.rollback();
        try self.setMetadataU64("clean_shutdown", 1);
        try self.commit();
        self.clean_shutdown_written = true;
    }

    /// Runs payload-free integrity diagnostics. It never repairs or mutates workflow facts.
    pub fn health(self: *Store) Error!store_health.Report {
        if (!self.onDispatcher()) return self.invoke(Store.health, .{});
        lock(&self.mutex);
        defer self.mutex.unlock();
        var report = store_health.Report{ .previous_shutdown_clean = self.previous_shutdown_clean, .recovery = self.recovery };
        report.schema_version = @intCast(try self.scalarU64("SELECT max(version) FROM spindle_schema_migration;"));
        report.migration_hashes_valid = self.migrationHashesValid();
        const quick_ok = try self.quickCheck();
        report.history_gaps = try self.scalarU64("SELECT count(*) FROM workflow_instance i WHERE i.next_sequence<>COALESCE((SELECT max(h.sequence)+1 FROM workflow_history h WHERE h.tenant=i.tenant AND h.namespace=i.namespace AND h.workflow_id=i.workflow_id),1) OR (SELECT count(*) FROM workflow_history h WHERE h.tenant=i.tenant AND h.namespace=i.namespace AND h.workflow_id=i.workflow_id)<>COALESCE((SELECT max(h.sequence) FROM workflow_history h WHERE h.tenant=i.tenant AND h.namespace=i.namespace AND h.workflow_id=i.workflow_id),0);");
        report.snapshot_checksum_failures = try self.snapshotFailures();
        report.orphan_records = try self.scalarU64("SELECT (SELECT count(*) FROM workflow_task t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL)+(SELECT count(*) FROM activity_task t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL)+(SELECT count(*) FROM durable_timer t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL)+(SELECT count(*) FROM outbox t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL);");
        report.pending_work = try self.scalarU64("SELECT (SELECT count(*) FROM workflow_task WHERE status IN ('ready','claimed'))+(SELECT count(*) FROM activity_task WHERE status_v2 IN ('ready','claimed'))+(SELECT count(*) FROM durable_timer WHERE status_v2 IN ('ready','claimed'))+(SELECT count(*) FROM outbox WHERE status_v2 IN ('ready','claimed'));");
        report.database_bytes = fileBytes(self.path);
        var wal_path: [1024]u8 = undefined;
        const wal = std.fmt.bufPrint(&wal_path, "{s}-wal", .{self.path}) catch return error.DatabaseFailure;
        report.wal_bytes = fileBytes(wal);
        report.last_checkpoint_utc_ms = @bitCast(try self.metadataU64("last_checkpoint_utc_ms"));
        report.integrity = if (!quick_ok or !report.migration_hashes_valid or report.history_gaps != 0 or report.snapshot_checksum_failures != 0 or report.orphan_records != 0) .corrupt else if (self.recovery.workflow_tasks + self.recovery.activities + self.recovery.timers + self.recovery.outbox != 0) .repairable_queue_state else .healthy;
        return report;
    }

    /// Uses SQLite's online backup API and validates the completed copy before returning.
    pub fn backup(self: *Store, destination: []const u8) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.backup, .{destination});
        lock(&self.mutex);
        defer self.mutex.unlock();
        const zpath = self.allocator.dupeZ(u8, destination) catch return error.DatabaseFailure;
        defer self.allocator.free(zpath);
        var raw: ?*c.sqlite3 = null;
        const open_result = c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_FULLMUTEX, null);
        if (open_result != c.SQLITE_OK) {
            if (raw) |handle| _ = c.sqlite3_close_v2(handle);
            return map(open_result);
        }
        const target = raw orelse return error.DatabaseFailure;
        var target_open = true;
        defer {
            if (target_open) _ = c.sqlite3_close_v2(target);
        }
        const handle = c.sqlite3_backup_init(target, "main", self.db, "main") orelse return map(c.sqlite3_errcode(target));
        const result = c.sqlite3_backup_step(handle, -1);
        const finish_result = c.sqlite3_backup_finish(handle);
        if (result != c.SQLITE_DONE or finish_result != c.SQLITE_OK) return if (result == c.SQLITE_BUSY or result == c.SQLITE_LOCKED) error.BackupInterrupted else map(if (finish_result == c.SQLITE_OK) result else finish_result);
        if (c.sqlite3_close_v2(target) != c.SQLITE_OK) return error.BackupInterrupted;
        target_open = false;
        if (!validateFile(self.allocator, destination)) return error.CorruptSchema;
    }

    /// Performs bounded maintenance on the store's blocking dispatcher, never a compute executor.
    pub fn maintain(self: *Store, options: store_health.Maintenance) Error!store_health.MaintenanceProgress {
        if (!self.onDispatcher()) return self.invoke(Store.maintain, .{options});
        lock(&self.mutex);
        defer self.mutex.unlock();
        var progress = store_health.MaintenanceProgress{};
        if (cancelled(options)) return error.MaintenanceCancelled;
        if (options.checkpoint) {
            var log_frames: c_int = 0;
            var checkpointed: c_int = 0;
            const result = c.sqlite3_wal_checkpoint_v2(self.db, null, c.SQLITE_CHECKPOINT_PASSIVE, &log_frames, &checkpointed);
            if (result != c.SQLITE_OK) return map(result);
            try self.setMetadataU64("last_checkpoint_utc_ms", @bitCast(self.clock.utcNow()));
            progress.checkpointed = true;
            progress.wal_frames = @intCast(@max(log_frames, 0));
            progress.checkpointed_frames = @intCast(@max(checkpointed, 0));
        }
        if (cancelled(options)) return error.MaintenanceCancelled;
        if (options.incremental_vacuum_pages != 0) {
            const before = try self.scalarU64("PRAGMA freelist_count;");
            var sql: [64:0]u8 = undefined;
            const query = std.fmt.bufPrintZ(&sql, "PRAGMA incremental_vacuum({d});", .{options.incremental_vacuum_pages}) catch return error.DatabaseFailure;
            try self.exec(query.ptr);
            const after = try self.scalarU64("PRAGMA freelist_count;");
            progress.vacuumed_pages = @intCast(before -| after);
        }
        return progress;
    }

    /// Explicit offline restore. The source is validated, the old database is preserved as `.failed`, and reopening increments the epoch.
    pub fn restoreOffline(allocator: std.mem.Allocator, path: []const u8, source: []const u8, clock: core.Clock) Error!Store {
        if (!validateFile(allocator, source)) return error.CorruptSchema;
        var failed: [1024:0]u8 = undefined;
        const failed_path = std.fmt.bufPrintZ(&failed, "{s}.failed", .{path}) catch return error.RestoreFailed;
        const io = std.Options.debug_io;
        std.Io.Dir.cwd().rename(path, std.Io.Dir.cwd(), failed_path, io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.RestoreFailed,
        };
        std.Io.Dir.cwd().rename(source, std.Io.Dir.cwd(), path, io) catch {
            std.Io.Dir.cwd().rename(failed_path, std.Io.Dir.cwd(), path, io) catch {};
            return error.RestoreFailed;
        };
        var restored = try Store.init(allocator, path, clock);
        errdefer restored.deinit();
        const report = try restored.health();
        if (report.integrity == .corrupt) return error.CorruptSchema;
        return restored;
    }

    pub fn migrate(self: *Store) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.migrate, .{});
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        try self.applyMigration();
        try self.commit();
    }

    pub fn start(self: *Store, value: Start) Error!core.StableId {
        if (!self.onDispatcher()) return self.invoke(Store.start, .{value});
        if (value.payload.len > max_payload_bytes) return error.PayloadTooLarge;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        const existing = try self.prepare("SELECT request_hash,workflow_id FROM workflow_start_idempotency WHERE tenant=?1 AND namespace=?2 AND idempotency_key=?3;");
        defer self.finalize(existing);
        try self.bindText(existing, 1, value.tenant);
        try self.bindText(existing, 2, value.namespace);
        try self.bindText(existing, 3, value.idempotency_key);
        if (try self.step(existing)) {
            if (self.columnInt(existing, 0) != value.request_hash) return error.IdempotencyConflict;
            const id = self.columnId(existing, 1);
            try self.commit();
            return id;
        }
        try self.insertInstance(value);
        try self.commit();
        return value.workflow_id;
    }

    pub fn appendInbox(self: *Store, value: Inbox) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.appendInbox, .{value});
        if (value.payload.len > max_payload_bytes) return error.PayloadTooLarge;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        const stmt = try self.prepare("INSERT OR IGNORE INTO inbox(tenant,namespace,message_id,workflow_id,payload) SELECT ?1,?2,?3,?4,?5 WHERE EXISTS(SELECT 1 FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?4);");
        defer self.finalize(stmt);
        try self.bindText(stmt, 1, value.tenant);
        try self.bindText(stmt, 2, value.namespace);
        try self.bindId(stmt, 3, value.message_id);
        try self.bindId(stmt, 4, value.workflow_id);
        try self.bindBlob(stmt, 5, value.payload);
        _ = try self.step(stmt);
        if (c.sqlite3_changes(self.db) == 0) {
            const known = try self.prepare("SELECT 1 FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3;");
            defer self.finalize(known);
            try self.bindText(known, 1, value.tenant);
            try self.bindText(known, 2, value.namespace);
            try self.bindId(known, 3, value.workflow_id);
            if (!try self.step(known)) return error.NotFound;
        } else {
            const sequence_query = try self.prepare("SELECT next_sequence FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND status='running';");
            defer self.finalize(sequence_query);
            try self.bindText(sequence_query, 1, value.tenant);
            try self.bindText(sequence_query, 2, value.namespace);
            try self.bindId(sequence_query, 3, value.workflow_id);
            if (!try self.step(sequence_query)) return error.NotFound;
            const sequence = self.columnInt(sequence_query, 0);
            const history = try self.prepare("INSERT INTO workflow_history(tenant,namespace,workflow_id,sequence,event_id,kind,event_utc_ms,schema_id,schema_version,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);");
            defer self.finalize(history);
            try self.bindText(history, 1, value.tenant);
            try self.bindText(history, 2, value.namespace);
            try self.bindId(history, 3, value.workflow_id);
            try self.bindInt(history, 4, sequence);
            try self.bindId(history, 5, value.event_id);
            try self.bindInt(history, 6, value.kind);
            try self.bindInt(history, 7, value.utc_ms);
            try self.bindInt(history, 8, @as(i64, @bitCast(value.schema.id)));
            try self.bindInt(history, 9, value.schema.version);
            try self.bindBlob(history, 10, value.payload);
            _ = try self.step(history);
            const update = try self.prepare("UPDATE workflow_instance SET next_sequence=next_sequence+1,updated_utc_ms=?4 WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3;");
            defer self.finalize(update);
            try self.bindText(update, 1, value.tenant);
            try self.bindText(update, 2, value.namespace);
            try self.bindId(update, 3, value.workflow_id);
            try self.bindInt(update, 4, value.utc_ms);
            _ = try self.step(update);
            const inbox_sequence = try self.prepare("UPDATE inbox SET event_sequence=?4 WHERE tenant=?1 AND namespace=?2 AND message_id=?3;");
            defer self.finalize(inbox_sequence);
            try self.bindText(inbox_sequence, 1, value.tenant);
            try self.bindText(inbox_sequence, 2, value.namespace);
            try self.bindId(inbox_sequence, 3, value.message_id);
            try self.bindInt(inbox_sequence, 4, sequence);
            _ = try self.step(inbox_sequence);
            const wake = try self.prepare("INSERT INTO workflow_task(task_id,tenant,namespace,workflow_id,status,available_utc_ms) SELECT ?1,?2,?3,?4,'ready',?5 WHERE NOT EXISTS(SELECT 1 FROM workflow_task WHERE tenant=?2 AND namespace=?3 AND workflow_id=?4 AND status IN ('ready','claimed'));");
            defer self.finalize(wake);
            try self.bindId(wake, 1, value.task_id);
            try self.bindText(wake, 2, value.tenant);
            try self.bindText(wake, 3, value.namespace);
            try self.bindId(wake, 4, value.workflow_id);
            try self.bindInt(wake, 5, value.utc_ms);
            _ = try self.step(wake);
        }
        try self.commit();
    }

    pub fn getInstance(self: *Store, tenant: []const u8, namespace: []const u8, id: core.StableId) Error!InstanceRecord {
        if (!self.onDispatcher()) return self.invoke(Store.getInstance, .{ tenant, namespace, id });
        lock(&self.mutex);
        defer self.mutex.unlock();
        const stmt = try self.prepare("SELECT definition_id,definition_version,status,state_version,state FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3;");
        defer self.finalize(stmt);
        try self.bindText(stmt, 1, tenant);
        try self.bindText(stmt, 2, namespace);
        try self.bindId(stmt, 3, id);
        if (!try self.step(stmt)) return error.NotFound;
        const state = self.allocator.dupe(u8, self.columnBlob(stmt, 4)) catch return error.DatabaseFailure;
        return .{ .id = id, .definition_id = @intCast(self.columnInt(stmt, 0)), .definition_version = @intCast(self.columnInt(stmt, 1)), .status = parseStatus(self.columnText(stmt, 2)), .state_version = @intCast(self.columnInt(stmt, 3)), .state = state };
    }

    /// Claims at most one activity for this runtime epoch. The returned payload is caller-owned.
    pub fn claimActivity(self: *Store, allocator: std.mem.Allocator, tenant: []const u8, namespace: []const u8) (Error || std.mem.Allocator.Error)!?ActivityClaim {
        if (!self.onDispatcher()) return self.invoke(Store.claimActivity, .{ allocator, tenant, namespace });
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        const s = try self.prepare("UPDATE activity_task SET status_v2='claimed',claimed_epoch=?1,attempt=attempt+1,started_utc_ms=?4,heartbeat_utc_ms=?4 WHERE task_id=(SELECT task_id FROM activity_task WHERE tenant=?2 AND namespace=?3 AND ((status_v2='ready' AND available_utc_ms<=?4) OR (status_v2='claimed' AND claimed_epoch<>?1)) ORDER BY available_utc_ms,task_id LIMIT 1) RETURNING task_id,workflow_id,command_sequence,attempt,scheduled_utc_ms,started_utc_ms,payload,schema_id,schema_version;");
        defer self.finalize(s);
        try self.bindInt(s, 1, self.runtime_epoch);
        try self.bindText(s, 2, tenant);
        try self.bindText(s, 3, namespace);
        try self.bindInt(s, 4, self.clock.utcNow());
        if (!try self.step(s)) {
            try self.commit();
            return null;
        }
        const result = ActivityClaim{ .allocator = allocator, .task_id = self.columnId(s, 0), .workflow_id = self.columnId(s, 1), .command_sequence = @intCast(self.columnInt(s, 2)), .attempt = @intCast(self.columnInt(s, 3)), .runtime_epoch = self.runtime_epoch, .scheduled_utc_ms = self.columnInt(s, 4), .started_utc_ms = self.columnInt(s, 5), .payload = try allocator.dupe(u8, self.columnBlob(s, 6)), .schema = .{ .id = @bitCast(self.columnInt(s, 7)), .version = @intCast(self.columnInt(s, 8)) } };
        _ = try self.step(s);
        try self.commit();
        return result;
    }
    /// Atomically records an activity result, wakes its workflow, and fences stale runtimes.
    pub fn finishActivity(self: *Store, claim: ActivityClaim, tenant: []const u8, namespace: []const u8, kind: u32, schema: core.schema.SchemaKey, payload: []const u8) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.finishActivity, .{ claim, tenant, namespace, kind, schema, payload });
        defer claim.allocator.free(claim.payload);
        try self.finishExternal("activity_task", "task_id", claim.task_id, claim.workflow_id, claim.runtime_epoch, tenant, namespace, kind, schema, payload);
    }
    pub fn heartbeatActivity(self: *Store, claim: ActivityClaim) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.heartbeatActivity, .{claim});
        lock(&self.mutex);
        defer self.mutex.unlock();
        const s = try self.prepare("UPDATE activity_task SET heartbeat_utc_ms=?3 WHERE task_id=?1 AND status_v2='claimed' AND claimed_epoch=?2;");
        defer self.finalize(s);
        try self.bindId(s, 1, claim.task_id);
        try self.bindInt(s, 2, claim.runtime_epoch);
        try self.bindInt(s, 3, self.clock.utcNow());
        _ = try self.step(s);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
    }
    /// Persists a deterministic retry decision and releases the claim in one transaction.
    pub fn retryActivity(self: *Store, claim: ActivityClaim, tenant: []const u8, namespace: []const u8, delay_ms: u64) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.retryActivity, .{ claim, tenant, namespace, delay_ms });
        defer claim.allocator.free(claim.payload);
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        if (try self.metadataU64("runtime_epoch") != claim.runtime_epoch) return error.StaleRuntimeEpoch;
        const now = self.clock.utcNow();
        const release = try self.prepare("UPDATE activity_task SET status_v2='ready',claimed_epoch=NULL,available_utc_ms=?3 WHERE task_id=?1 AND status_v2='claimed' AND claimed_epoch=?2;");
        defer self.finalize(release);
        try self.bindId(release, 1, claim.task_id);
        try self.bindInt(release, 2, claim.runtime_epoch);
        try self.bindInt(release, 3, now + @as(i64, @intCast(delay_ms)));
        _ = try self.step(release);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
        var retry_metadata: [12]u8 = undefined;
        std.mem.writeInt(u32, retry_metadata[0..4], claim.attempt, .big);
        std.mem.writeInt(u64, retry_metadata[4..12], delay_ms, .big);
        try self.appendHistoryFact(tenant, namespace, claim.workflow_id, derivedEventId(claim.task_id, @intCast(claim.attempt)), event.Kind.activity_retry_scheduled, .{ .id = 0x6163_7469_7669_7479, .version = 1 }, &retry_metadata, now);
        try self.commit();
    }
    pub fn activityCancelled(self: *Store, claim: ActivityClaim, tenant: []const u8, namespace: []const u8) Error!bool {
        if (!self.onDispatcher()) return self.invoke(Store.activityCancelled, .{ claim, tenant, namespace });
        lock(&self.mutex);
        defer self.mutex.unlock();
        const s = try self.prepare("SELECT 1 FROM workflow_history WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND kind=?4 LIMIT 1;");
        defer self.finalize(s);
        try self.bindText(s, 1, tenant);
        try self.bindText(s, 2, namespace);
        try self.bindId(s, 3, claim.workflow_id);
        try self.bindInt(s, 4, event.Kind.cancellation_requested);
        return try self.step(s);
    }
    pub fn claimTimer(self: *Store, allocator: std.mem.Allocator, tenant: []const u8, namespace: []const u8) (Error || std.mem.Allocator.Error)!?TimerClaim {
        if (!self.onDispatcher()) return self.invoke(Store.claimTimer, .{ allocator, tenant, namespace });
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        const s = try self.prepare("UPDATE durable_timer SET status_v2='claimed',claimed_epoch=?1 WHERE timer_id=(SELECT timer_id FROM durable_timer WHERE tenant=?2 AND namespace=?3 AND fire_at_utc_ms<=?4 AND (status_v2='ready' OR (status_v2='claimed' AND claimed_epoch<>?1)) ORDER BY fire_at_utc_ms,timer_id LIMIT 1) RETURNING timer_id,workflow_id,payload,schema_id,schema_version;");
        defer self.finalize(s);
        try self.bindInt(s, 1, self.runtime_epoch);
        try self.bindText(s, 2, tenant);
        try self.bindText(s, 3, namespace);
        try self.bindInt(s, 4, self.clock.utcNow());
        if (!try self.step(s)) {
            try self.commit();
            return null;
        }
        const value = TimerClaim{ .allocator = allocator, .timer_id = self.columnId(s, 0), .workflow_id = self.columnId(s, 1), .runtime_epoch = self.runtime_epoch, .payload = try allocator.dupe(u8, self.columnBlob(s, 2)), .schema = .{ .id = @bitCast(self.columnInt(s, 3)), .version = @intCast(self.columnInt(s, 4)) } };
        _ = try self.step(s);
        try self.commit();
        return value;
    }
    pub fn fireTimer(self: *Store, claim: TimerClaim, tenant: []const u8, namespace: []const u8, schema: core.schema.SchemaKey) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.fireTimer, .{ claim, tenant, namespace, schema });
        defer claim.allocator.free(claim.payload);
        try self.finishExternal("durable_timer", "timer_id", claim.timer_id, claim.workflow_id, claim.runtime_epoch, tenant, namespace, event.Kind.timer_fired, schema, claim.payload);
    }
    pub fn claimOutbox(self: *Store, allocator: std.mem.Allocator, tenant: []const u8, namespace: []const u8) (Error || std.mem.Allocator.Error)!?OutboxClaim {
        if (!self.onDispatcher()) return self.invoke(Store.claimOutbox, .{ allocator, tenant, namespace });
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        const s = try self.prepare("UPDATE outbox SET status_v2='claimed',claimed_epoch=?1 WHERE message_id=(SELECT message_id FROM outbox WHERE tenant=?2 AND namespace=?3 AND (status_v2='ready' OR (status_v2='claimed' AND claimed_epoch<>?1)) ORDER BY message_id LIMIT 1) RETURNING message_id,workflow_id,payload;");
        defer self.finalize(s);
        try self.bindInt(s, 1, self.runtime_epoch);
        try self.bindText(s, 2, tenant);
        try self.bindText(s, 3, namespace);
        if (!try self.step(s)) {
            try self.commit();
            return null;
        }
        const value = OutboxClaim{ .allocator = allocator, .message_id = self.columnId(s, 0), .workflow_id = self.columnId(s, 1), .runtime_epoch = self.runtime_epoch, .payload = try allocator.dupe(u8, self.columnBlob(s, 2)) };
        _ = try self.step(s);
        try self.commit();
        return value;
    }
    pub fn finishOutbox(self: *Store, claim: OutboxClaim) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.finishOutbox, .{claim});
        defer claim.allocator.free(claim.payload);
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (try self.metadataU64("runtime_epoch") != claim.runtime_epoch) return error.StaleRuntimeEpoch;
        const s = try self.prepare("UPDATE outbox SET status_v2='completed',published_utc_ms=?3 WHERE message_id=?1 AND status_v2='claimed' AND claimed_epoch=?2;");
        defer self.finalize(s);
        try self.bindId(s, 1, claim.message_id);
        try self.bindInt(s, 2, claim.runtime_epoch);
        try self.bindInt(s, 3, self.clock.utcNow());
        _ = try self.step(s);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
    }
    pub fn abandonOutbox(self: *Store, claim: OutboxClaim) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.abandonOutbox, .{claim});
        defer claim.allocator.free(claim.payload);
        lock(&self.mutex);
        defer self.mutex.unlock();
        const s = try self.prepare("UPDATE outbox SET status_v2='ready',claimed_epoch=NULL WHERE message_id=?1 AND status_v2='claimed' AND claimed_epoch=?2;");
        defer self.finalize(s);
        try self.bindId(s, 1, claim.message_id);
        try self.bindInt(s, 2, claim.runtime_epoch);
        _ = try self.step(s);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
    }

    /// Atomically claims the next ready task or a claim fenced by an older runtime epoch.
    pub fn claimWorkflowTask(self: *Store, tenant: []const u8, namespace: []const u8) Error!?Claim {
        if (!self.onDispatcher()) return self.invoke(Store.claimWorkflowTask, .{ tenant, namespace });
        const now = self.clock.utcNow();
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        const stmt = try self.prepare(
            "UPDATE workflow_task SET status='claimed',claimed_epoch=?1 " ++
                "WHERE task_id=(SELECT task_id FROM workflow_task WHERE tenant=?2 AND namespace=?3 AND " ++
                "((status='ready' AND available_utc_ms<=?4) OR (status='claimed' AND claimed_epoch<>?1)) " ++
                "ORDER BY available_utc_ms,task_id LIMIT 1) " ++
                "RETURNING task_id,workflow_id;",
        );
        defer self.finalize(stmt);
        try self.bindInt(stmt, 1, self.runtime_epoch);
        try self.bindText(stmt, 2, tenant);
        try self.bindText(stmt, 3, namespace);
        try self.bindInt(stmt, 4, now);
        if (!try self.step(stmt)) {
            try self.commit();
            return null;
        }
        const task_id = self.columnId(stmt, 0);
        const workflow_id = self.columnId(stmt, 1);
        _ = try self.step(stmt);
        const metadata = try self.prepare("SELECT state_version,definition_id,definition_version FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3;");
        defer self.finalize(metadata);
        try self.bindText(metadata, 1, tenant);
        try self.bindText(metadata, 2, namespace);
        try self.bindId(metadata, 3, workflow_id);
        if (!try self.step(metadata)) return error.CorruptSchema;
        const result = Claim{
            .task_id = task_id,
            .workflow_id = workflow_id,
            .state_version = @intCast(self.columnInt(metadata, 0)),
            .definition_id = @bitCast(self.columnInt(metadata, 1)),
            .definition_version = @intCast(self.columnInt(metadata, 2)),
            .runtime_epoch = self.runtime_epoch,
        };
        try self.commit();
        return result;
    }

    /// Loads owned replay input for a claim. No transaction remains open after return.
    pub fn loadWorkflowTask(self: *Store, allocator: std.mem.Allocator, claim: Claim) (Error || std.mem.Allocator.Error)!LoadedTask {
        if (!self.onDispatcher()) return self.invoke(Store.loadWorkflowTask, .{ allocator, claim });
        lock(&self.mutex);
        defer self.mutex.unlock();
        const row = try self.prepare("SELECT t.tenant,t.namespace,i.state,i.last_processed_decision_seq FROM workflow_task t JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE t.task_id=?1 AND t.workflow_id=?2 AND t.status='claimed' AND t.claimed_epoch=?3;");
        defer self.finalize(row);
        try self.bindId(row, 1, claim.task_id);
        try self.bindId(row, 2, claim.workflow_id);
        try self.bindInt(row, 3, claim.runtime_epoch);
        if (!try self.step(row)) return error.StaleRuntimeEpoch;
        const tenant = try allocator.dupe(u8, self.columnText(row, 0));
        errdefer allocator.free(tenant);
        const namespace = try allocator.dupe(u8, self.columnText(row, 1));
        errdefer allocator.free(namespace);
        const state = try allocator.dupe(u8, self.columnBlob(row, 2));
        errdefer allocator.free(state);
        const last: u64 = @intCast(self.columnInt(row, 3));
        const history = try self.prepare("SELECT sequence,kind,event_utc_ms,schema_id,schema_version,payload FROM workflow_history WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND sequence>?4 ORDER BY sequence;");
        defer self.finalize(history);
        try self.bindText(history, 1, tenant);
        try self.bindText(history, 2, namespace);
        try self.bindId(history, 3, claim.workflow_id);
        try self.bindInt(history, 4, last);
        var events: std.ArrayListUnmanaged(event.Event) = .empty;
        errdefer {
            for (events.items) |value| allocator.free(value.payload.bytes);
            events.deinit(allocator);
        }
        var expected = last + 1;
        while (try self.step(history)) {
            const sequence: u64 = @intCast(self.columnInt(history, 0));
            if (sequence != expected) return error.CorruptSchema;
            expected += 1;
            const payload = try allocator.dupe(u8, self.columnBlob(history, 5));
            errdefer allocator.free(payload);
            try events.append(allocator, .{
                .sequence = sequence,
                .kind = @intCast(self.columnInt(history, 1)),
                .utc_ms = self.columnInt(history, 2),
                .payload = .{ .schema = .{ .id = @bitCast(self.columnInt(history, 3)), .version = @intCast(self.columnInt(history, 4)) }, .bytes = payload },
            });
        }
        return .{ .allocator = allocator, .claim = claim, .tenant = tenant, .namespace = namespace, .state = state, .last_processed_sequence = last, .events = try events.toOwnedSlice(allocator) };
    }

    /// Leaves unknown-definition work blocked without changing instance history.
    pub fn blockWorkflowTask(self: *Store, claim: Claim) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.blockWorkflowTask, .{claim});
        lock(&self.mutex);
        defer self.mutex.unlock();
        const stmt = try self.prepare("UPDATE workflow_task SET status='blocked',blocked_definition_id=?4,blocked_definition_version=?5 WHERE task_id=?1 AND workflow_id=?2 AND status='claimed' AND claimed_epoch=?3;");
        defer self.finalize(stmt);
        try self.bindId(stmt, 1, claim.task_id);
        try self.bindId(stmt, 2, claim.workflow_id);
        try self.bindInt(stmt, 3, claim.runtime_epoch);
        try self.bindInt(stmt, 4, @as(i64, @bitCast(claim.definition_id)));
        try self.bindInt(stmt, 5, claim.definition_version);
        _ = try self.step(stmt);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
    }

    /// Explicitly unblocks tasks pinned to one exact registered definition version.
    pub fn unblockDefinition(self: *Store, definition_id: u64, definition_version: u32) Error!usize {
        if (!self.onDispatcher()) return self.invoke(Store.unblockDefinition, .{ definition_id, definition_version });
        const now = self.clock.utcNow();
        lock(&self.mutex);
        defer self.mutex.unlock();
        const stmt = try self.prepare("UPDATE workflow_task SET status='ready',available_utc_ms=?3,claimed_epoch=NULL,blocked_definition_id=NULL,blocked_definition_version=NULL WHERE status='blocked' AND blocked_definition_id=?1 AND blocked_definition_version=?2;");
        defer self.finalize(stmt);
        try self.bindInt(stmt, 1, @as(i64, @bitCast(definition_id)));
        try self.bindInt(stmt, 2, definition_version);
        try self.bindInt(stmt, 3, now);
        _ = try self.step(stmt);
        return @intCast(c.sqlite3_changes(self.db));
    }

    /// Atomically fences and publishes one deterministic workflow transition.
    pub fn commitWorkflowTaskTransition(self: *Store, value: Commit) Error!void {
        if (!self.onDispatcher()) return self.invoke(Store.commitWorkflowTaskTransition, .{value});
        if (value.state.len > max_payload_bytes) return error.PayloadTooLarge;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        if (try self.metadataU64("runtime_epoch") != value.claim.runtime_epoch) return error.StaleRuntimeEpoch;
        const update = try self.prepare("UPDATE workflow_instance SET state=?6,status=?7,state_version=state_version+1,last_processed_decision_seq=?8,updated_utc_ms=?9 WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND state_version=?4 AND definition_id=?10 AND definition_version=?11 AND EXISTS(SELECT 1 FROM workflow_task WHERE task_id=?5 AND workflow_id=?3 AND status='claimed' AND claimed_epoch=?12);");
        defer self.finalize(update);
        try self.bindText(update, 1, value.tenant);
        try self.bindText(update, 2, value.namespace);
        try self.bindId(update, 3, value.claim.workflow_id);
        try self.bindInt(update, 4, value.claim.state_version);
        try self.bindId(update, 5, value.claim.task_id);
        try self.bindBlob(update, 6, value.state);
        try self.bindText(update, 7, statusText(value.status));
        try self.bindInt(update, 8, value.last_processed_sequence);
        try self.bindInt(update, 9, value.updated_utc_ms);
        try self.bindInt(update, 10, @as(i64, @bitCast(value.claim.definition_id)));
        try self.bindInt(update, 11, value.claim.definition_version);
        try self.bindInt(update, 12, value.claim.runtime_epoch);
        _ = try self.step(update);
        if (c.sqlite3_changes(self.db) != 1) return error.Conflict;
        if (value.optional_snapshot) |saved| try self.insertSnapshot(value.tenant, value.namespace, saved);
        try self.insertScheduled(value.tenant, value.namespace, value.claim.workflow_id, value.scheduled);
        if (value.status != .running) try self.applyParentClosePolicies(value.tenant, value.namespace, value.claim.workflow_id, value.status, value.updated_utc_ms);
        if (value.status != .running) try self.notifyParent(value.tenant, value.namespace, value.claim.workflow_id, value.status, value.updated_utc_ms);
        const task = try self.prepare("UPDATE workflow_task SET status=CASE WHEN EXISTS(SELECT 1 FROM workflow_history WHERE tenant=?2 AND namespace=?3 AND workflow_id=?4 AND sequence>?5) THEN 'ready' ELSE 'completed' END,available_utc_ms=?6,claimed_epoch=NULL WHERE task_id=?1 AND claimed_epoch=?7;");
        defer self.finalize(task);
        try self.bindId(task, 1, value.claim.task_id);
        try self.bindText(task, 2, value.tenant);
        try self.bindText(task, 3, value.namespace);
        try self.bindId(task, 4, value.claim.workflow_id);
        try self.bindInt(task, 5, value.last_processed_sequence);
        try self.bindInt(task, 6, value.updated_utc_ms);
        try self.bindInt(task, 7, value.claim.runtime_epoch);
        _ = try self.step(task);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
        try self.commit();
    }

    pub const Start = struct { workflow_id: core.StableId, task_id: core.StableId, event_id: core.StableId, tenant: []const u8, namespace: []const u8, idempotency_key: []const u8, request_hash: i64, definition_id: u64, definition_version: u32, schema: core.schema.SchemaKey, payload: []const u8, utc_ms: i64 };
    pub const Inbox = struct { task_id: core.StableId, event_id: core.StableId, message_id: core.StableId, workflow_id: core.StableId, tenant: []const u8, namespace: []const u8, kind: u32, schema: core.schema.SchemaKey, payload: []const u8, utc_ms: i64 };
    fn insertInstance(self: *Store, v: Start) Error!void {
        const s = try self.prepare("INSERT INTO workflow_instance(tenant,namespace,workflow_id,definition_id,definition_version,status,state,next_sequence,created_utc_ms,updated_utc_ms) VALUES(?1,?2,?3,?4,?5,'running',X'',2,?6,?6);");
        defer self.finalize(s);
        try self.bindText(s, 1, v.tenant);
        try self.bindText(s, 2, v.namespace);
        try self.bindId(s, 3, v.workflow_id);
        try self.bindInt(s, 4, @as(i64, @bitCast(v.definition_id)));
        try self.bindInt(s, 5, v.definition_version);
        try self.bindInt(s, 6, v.utc_ms);
        _ = try self.step(s);
        const h = try self.prepare("INSERT INTO workflow_history(tenant,namespace,workflow_id,sequence,event_id,kind,event_utc_ms,schema_id,schema_version,payload) VALUES(?1,?2,?3,1,?4,1,?5,?6,?7,?8);");
        defer self.finalize(h);
        try self.bindText(h, 1, v.tenant);
        try self.bindText(h, 2, v.namespace);
        try self.bindId(h, 3, v.workflow_id);
        try self.bindId(h, 4, v.event_id);
        try self.bindInt(h, 5, v.utc_ms);
        try self.bindInt(h, 6, @as(i64, @bitCast(v.schema.id)));
        try self.bindInt(h, 7, v.schema.version);
        try self.bindBlob(h, 8, v.payload);
        _ = try self.step(h);
        const t = try self.prepare("INSERT INTO workflow_task(task_id,tenant,namespace,workflow_id,status,available_utc_ms) VALUES(?1,?2,?3,?4,'ready',?5);");
        defer self.finalize(t);
        try self.bindId(t, 1, v.task_id);
        try self.bindText(t, 2, v.tenant);
        try self.bindText(t, 3, v.namespace);
        try self.bindId(t, 4, v.workflow_id);
        try self.bindInt(t, 5, v.utc_ms);
        _ = try self.step(t);
        const i = try self.prepare("INSERT INTO workflow_start_idempotency(tenant,namespace,idempotency_key,request_hash,workflow_id) VALUES(?1,?2,?3,?4,?5);");
        defer self.finalize(i);
        try self.bindText(i, 1, v.tenant);
        try self.bindText(i, 2, v.namespace);
        try self.bindText(i, 3, v.idempotency_key);
        try self.bindInt(i, 4, v.request_hash);
        try self.bindId(i, 5, v.workflow_id);
        _ = try self.step(i);
    }
    fn onDispatcher(self: *Store) bool {
        return self.dispatcher.executor().isWorkerThread();
    }
    fn invoke(self: *Store, comptime function: anytype, args: anytype) @typeInfo(@TypeOf(function)).@"fn".return_type.? {
        const Return = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
        const Args = @TypeOf(args);
        const Context = struct {
            store: *Store,
            args: Args,
            result: Return = undefined,
            fn run(task: *executor.Task) void {
                const context: *@This() = @ptrCast(@alignCast(task.context.?));
                context.result = @call(.auto, function, .{context.store} ++ context.args);
            }
        };
        var context = Context{ .store = self, .args = args };
        var task = executor.Task.init(Context.run, &context);
        self.dispatcher.submit(&task, .{}) catch return error.DatabaseFailure;
        task.wait() catch return error.DatabaseFailure;
        task.waitQueueReleased() catch return error.DatabaseFailure;
        return context.result;
    }
    fn insertSnapshot(self: *Store, tenant: []const u8, namespace: []const u8, saved: snapshot.Snapshot) Error!void {
        if (!snapshot.verify(saved) or saved.state.len > max_payload_bytes) return error.CorruptSchema;
        const stmt = try self.prepare("INSERT INTO workflow_snapshot(tenant,namespace,workflow_id,event_sequence,definition_version,state,checksum) VALUES(?1,?2,?3,?4,?5,?6,?7) ON CONFLICT(tenant,namespace,workflow_id,event_sequence) DO UPDATE SET definition_version=excluded.definition_version,state=excluded.state,checksum=excluded.checksum;");
        defer self.finalize(stmt);
        try self.bindText(stmt, 1, tenant);
        try self.bindText(stmt, 2, namespace);
        try self.bindId(stmt, 3, saved.workflow_id);
        try self.bindInt(stmt, 4, saved.event_sequence);
        try self.bindInt(stmt, 5, saved.definition_version);
        try self.bindBlob(stmt, 6, saved.state);
        try self.bindInt(stmt, 7, @as(i64, @bitCast(saved.checksum)));
        _ = try self.step(stmt);
    }
    fn insertScheduled(self: *Store, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, scheduled: persistence.ScheduledWork) Error!void {
        for (scheduled.activities) |activity| {
            if (activity.payload.len > max_payload_bytes) return error.PayloadTooLarge;
            const stmt = try self.prepare("INSERT OR IGNORE INTO activity_task(task_id,tenant,namespace,workflow_id,command_sequence,payload,schema_id,schema_version,available_utc_ms,scheduled_utc_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?9);");
            defer self.finalize(stmt);
            try self.bindId(stmt, 1, activity.task_id);
            try self.bindText(stmt, 2, tenant);
            try self.bindText(stmt, 3, namespace);
            try self.bindId(stmt, 4, workflow_id);
            try self.bindInt(stmt, 5, activity.command_sequence);
            try self.bindBlob(stmt, 6, activity.payload);
            try self.bindInt(stmt, 7, @as(i64, @bitCast(activity.schema.id)));
            try self.bindInt(stmt, 8, activity.schema.version);
            try self.bindInt(stmt, 9, self.clock.utcNow());
            _ = try self.step(stmt);
        }
        for (scheduled.timers) |timer| {
            if (timer.payload.len > max_payload_bytes) return error.PayloadTooLarge;
            const stmt = try self.prepare("INSERT OR IGNORE INTO durable_timer(timer_id,tenant,namespace,workflow_id,fire_at_utc_ms,payload,schema_id,schema_version) VALUES(?1,?2,?3,?4,?5,?6,?7,?8);");
            defer self.finalize(stmt);
            try self.bindId(stmt, 1, timer.timer_id);
            try self.bindText(stmt, 2, tenant);
            try self.bindText(stmt, 3, namespace);
            try self.bindId(stmt, 4, workflow_id);
            try self.bindInt(stmt, 5, timer.fire_at_utc_ms);
            try self.bindBlob(stmt, 6, timer.payload);
            try self.bindInt(stmt, 7, @as(i64, @bitCast(timer.schema.id)));
            try self.bindInt(stmt, 8, timer.schema.version);
            _ = try self.step(stmt);
        }
        for (scheduled.outbox) |message| {
            if (message.payload.len > max_payload_bytes) return error.PayloadTooLarge;
            const stmt = try self.prepare("INSERT OR IGNORE INTO outbox(message_id,tenant,namespace,workflow_id,payload) VALUES(?1,?2,?3,?4,?5);");
            defer self.finalize(stmt);
            try self.bindId(stmt, 1, message.message_id);
            try self.bindText(stmt, 2, tenant);
            try self.bindText(stmt, 3, namespace);
            try self.bindId(stmt, 4, workflow_id);
            try self.bindBlob(stmt, 5, message.payload);
            _ = try self.step(stmt);
        }
        for (scheduled.children) |value| try self.insertChild(tenant, namespace, workflow_id, value);
        for (scheduled.child_cancellations) |value| try self.appendHistoryFact(tenant, namespace, value.workflow_id, value.event_id, event.Kind.cancellation_requested, .{ .id = 0, .version = 1 }, "", self.clock.utcNow());
        for (scheduled.compensations) |value| try self.insertCompensation(tenant, namespace, workflow_id, value);
    }
    fn insertChild(self: *Store, tenant: []const u8, namespace: []const u8, parent_id: core.StableId, value: persistence.ChildStart) Error!void {
        if (value.payload.len > max_payload_bytes) return error.PayloadTooLarge;
        const instance_stmt = try self.prepare("INSERT OR IGNORE INTO workflow_instance(tenant,namespace,workflow_id,definition_id,definition_version,status,state,next_sequence,created_utc_ms,updated_utc_ms) VALUES(?1,?2,?3,?4,?5,'running',X'',2,?6,?6);");
        defer self.finalize(instance_stmt);
        try self.bindText(instance_stmt, 1, tenant);
        try self.bindText(instance_stmt, 2, namespace);
        try self.bindId(instance_stmt, 3, value.workflow_id);
        try self.bindInt(instance_stmt, 4, @as(i64, @bitCast(value.definition_id)));
        try self.bindInt(instance_stmt, 5, value.definition_version);
        try self.bindInt(instance_stmt, 6, self.clock.utcNow());
        _ = try self.step(instance_stmt);
        const history = try self.prepare("INSERT OR IGNORE INTO workflow_history(tenant,namespace,workflow_id,sequence,event_id,kind,event_utc_ms,schema_id,schema_version,payload) VALUES(?1,?2,?3,1,?4,?5,?6,?7,?8,?9);");
        defer self.finalize(history);
        try self.bindText(history, 1, tenant);
        try self.bindText(history, 2, namespace);
        try self.bindId(history, 3, value.workflow_id);
        try self.bindId(history, 4, value.event_id);
        try self.bindInt(history, 5, event.Kind.started);
        try self.bindInt(history, 6, self.clock.utcNow());
        try self.bindInt(history, 7, @as(i64, @bitCast(value.schema.id)));
        try self.bindInt(history, 8, value.schema.version);
        try self.bindBlob(history, 9, value.payload);
        _ = try self.step(history);
        const task = try self.prepare("INSERT OR IGNORE INTO workflow_task(task_id,tenant,namespace,workflow_id,status,available_utc_ms) VALUES(?1,?2,?3,?4,'ready',?5);");
        defer self.finalize(task);
        try self.bindId(task, 1, value.task_id);
        try self.bindText(task, 2, tenant);
        try self.bindText(task, 3, namespace);
        try self.bindId(task, 4, value.workflow_id);
        try self.bindInt(task, 5, self.clock.utcNow());
        _ = try self.step(task);
        const relation = try self.prepare("INSERT OR IGNORE INTO workflow_child(tenant,namespace,parent_workflow_id,child_workflow_id,parent_close_policy) VALUES(?1,?2,?3,?4,?5);");
        defer self.finalize(relation);
        try self.bindText(relation, 1, tenant);
        try self.bindText(relation, 2, namespace);
        try self.bindId(relation, 3, parent_id);
        try self.bindId(relation, 4, value.workflow_id);
        try self.bindInt(relation, 5, value.parent_close_policy);
        _ = try self.step(relation);
        const raw = value.workflow_id.toBytes();
        try self.appendHistoryFact(tenant, namespace, parent_id, derivedEventId(value.workflow_id, 10), event.Kind.child_started, @import("child.zig").schema, &raw, self.clock.utcNow());
    }
    fn insertCompensation(self: *Store, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, value: persistence.Compensation) Error!void {
        const plan = try self.prepare("INSERT OR IGNORE INTO compensation_plan(tenant,namespace,workflow_id,plan_id,status) VALUES(?1,?2,?3,?4,'running');");
        defer self.finalize(plan);
        try self.bindText(plan, 1, tenant);
        try self.bindText(plan, 2, namespace);
        try self.bindId(plan, 3, workflow_id);
        try self.bindId(plan, 4, value.plan_id);
        _ = try self.step(plan);
        const step_stmt = try self.prepare("INSERT OR IGNORE INTO compensation_step(tenant,namespace,plan_id,step_index,activity_type,schema_id,schema_version,input_hash,payload,status) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,'pending');");
        defer self.finalize(step_stmt);
        try self.bindText(step_stmt, 1, tenant);
        try self.bindText(step_stmt, 2, namespace);
        try self.bindId(step_stmt, 3, value.plan_id);
        try self.bindInt(step_stmt, 4, value.index);
        try self.bindInt(step_stmt, 5, @as(i64, @bitCast(value.activity_type)));
        try self.bindInt(step_stmt, 6, @as(i64, @bitCast(value.schema.id)));
        try self.bindInt(step_stmt, 7, value.schema.version);
        try self.bindInt(step_stmt, 8, @as(i64, @bitCast(value.input_hash)));
        try self.bindBlob(step_stmt, 9, value.payload);
        _ = try self.step(step_stmt);
        const task = try self.prepare("INSERT OR IGNORE INTO activity_task(task_id,tenant,namespace,workflow_id,command_sequence,payload,schema_id,schema_version,available_utc_ms,scheduled_utc_ms) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?9);");
        defer self.finalize(task);
        try self.bindId(task, 1, value.task_id);
        try self.bindText(task, 2, tenant);
        try self.bindText(task, 3, namespace);
        try self.bindId(task, 4, workflow_id);
        try self.bindInt(task, 5, value.command_sequence);
        try self.bindBlob(task, 6, value.payload);
        try self.bindInt(task, 7, @as(i64, @bitCast(value.schema.id)));
        try self.bindInt(task, 8, value.schema.version);
        try self.bindInt(task, 9, self.clock.utcNow());
        _ = try self.step(task);
    }
    fn notifyParent(self: *Store, tenant: []const u8, namespace: []const u8, child_id: core.StableId, status: instance.Status, utc_ms: i64) Error!void {
        const relation = try self.prepare("SELECT parent_workflow_id FROM workflow_child WHERE tenant=?1 AND namespace=?2 AND child_workflow_id=?3 AND notification_status='pending';");
        defer self.finalize(relation);
        try self.bindText(relation, 1, tenant);
        try self.bindText(relation, 2, namespace);
        try self.bindId(relation, 3, child_id);
        if (!try self.step(relation)) return;
        const parent_id = self.columnId(relation, 0);
        const raw = child_id.toBytes();
        const kind = switch (status) {
            .completed => event.Kind.child_completed,
            .failed => event.Kind.child_failed,
            .cancelled => event.Kind.child_cancelled,
            .running => return,
        };
        try self.appendHistoryFact(tenant, namespace, parent_id, derivedEventId(child_id, kind), kind, @import("child.zig").schema, &raw, utc_ms);
        try self.wakeWorkflow(tenant, namespace, parent_id, derivedEventId(child_id, kind + 1), utc_ms);
        const update = try self.prepare("UPDATE workflow_child SET notification_status=?4 WHERE tenant=?1 AND namespace=?2 AND child_workflow_id=?3 AND notification_status='pending';");
        defer self.finalize(update);
        try self.bindText(update, 1, tenant);
        try self.bindText(update, 2, namespace);
        try self.bindId(update, 3, child_id);
        try self.bindText(update, 4, statusText(status));
        _ = try self.step(update);
    }
    fn applyParentClosePolicies(self: *Store, tenant: []const u8, namespace: []const u8, parent_id: core.StableId, _: instance.Status, utc_ms: i64) Error!void {
        const rows = try self.prepare("SELECT child_workflow_id,parent_close_policy FROM workflow_child WHERE tenant=?1 AND namespace=?2 AND parent_workflow_id=?3 AND notification_status='pending';");
        defer self.finalize(rows);
        try self.bindText(rows, 1, tenant);
        try self.bindText(rows, 2, namespace);
        try self.bindId(rows, 3, parent_id);
        while (try self.step(rows)) {
            const child_id = self.columnId(rows, 0);
            const policy = self.columnInt(rows, 1);
            if (policy == 2) {
                try self.appendHistoryFact(tenant, namespace, child_id, derivedEventId(parent_id, 2), event.Kind.cancellation_requested, .{ .id = 0, .version = 1 }, "", utc_ms);
                try self.wakeWorkflow(tenant, namespace, child_id, derivedEventId(parent_id, 4), utc_ms);
            } else if (policy == 3) {
                try self.appendHistoryFact(tenant, namespace, child_id, derivedEventId(parent_id, 3), event.Kind.workflow_terminated, .{ .id = 0, .version = 1 }, "", utc_ms);
                const update = try self.prepare("UPDATE workflow_instance SET status='cancelled',updated_utc_ms=?4 WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND status='running';");
                defer self.finalize(update);
                try self.bindText(update, 1, tenant);
                try self.bindText(update, 2, namespace);
                try self.bindId(update, 3, child_id);
                try self.bindInt(update, 4, utc_ms);
                _ = try self.step(update);
            }
        }
    }
    fn wakeWorkflow(self: *Store, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, task_id: core.StableId, utc_ms: i64) Error!void {
        const wake = try self.prepare("INSERT INTO workflow_task(task_id,tenant,namespace,workflow_id,status,available_utc_ms) SELECT ?1,?2,?3,?4,'ready',?5 WHERE NOT EXISTS(SELECT 1 FROM workflow_task WHERE tenant=?2 AND namespace=?3 AND workflow_id=?4 AND status IN ('ready','claimed'));");
        defer self.finalize(wake);
        try self.bindId(wake, 1, task_id);
        try self.bindText(wake, 2, tenant);
        try self.bindText(wake, 3, namespace);
        try self.bindId(wake, 4, workflow_id);
        try self.bindInt(wake, 5, utc_ms);
        _ = try self.step(wake);
    }
    fn finishExternal(self: *Store, comptime table: []const u8, comptime id_column: []const u8, id: core.StableId, workflow_id: core.StableId, epoch: u64, tenant: []const u8, namespace: []const u8, kind: u32, schema: core.schema.SchemaKey, payload: []const u8) Error!void {
        if (payload.len > max_payload_bytes) return error.PayloadTooLarge;
        lock(&self.mutex);
        defer self.mutex.unlock();
        try self.begin();
        errdefer self.rollback();
        if (try self.metadataU64("runtime_epoch") != epoch) return error.StaleRuntimeEpoch;
        const done = try self.prepare("UPDATE " ++ table ++ " SET status_v2='completed' WHERE " ++ id_column ++ "=?1 AND status_v2='claimed' AND claimed_epoch=?2;");
        defer self.finalize(done);
        try self.bindId(done, 1, id);
        try self.bindInt(done, 2, epoch);
        _ = try self.step(done);
        if (c.sqlite3_changes(self.db) != 1) return error.StaleRuntimeEpoch;
        const seq = try self.prepare("SELECT next_sequence FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND status='running';");
        defer self.finalize(seq);
        try self.bindText(seq, 1, tenant);
        try self.bindText(seq, 2, namespace);
        try self.bindId(seq, 3, workflow_id);
        if (!try self.step(seq)) return error.NotFound;
        const sequence = self.columnInt(seq, 0);
        const history = try self.prepare("INSERT INTO workflow_history(tenant,namespace,workflow_id,sequence,event_id,kind,event_utc_ms,schema_id,schema_version,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);");
        defer self.finalize(history);
        try self.bindText(history, 1, tenant);
        try self.bindText(history, 2, namespace);
        try self.bindId(history, 3, workflow_id);
        try self.bindInt(history, 4, sequence);
        try self.bindId(history, 5, derivedEventId(id, sequence));
        try self.bindInt(history, 6, kind);
        try self.bindInt(history, 7, self.clock.utcNow());
        try self.bindInt(history, 8, @as(i64, @bitCast(schema.id)));
        try self.bindInt(history, 9, schema.version);
        try self.bindBlob(history, 10, payload);
        _ = try self.step(history);
        const instance_update = try self.prepare("UPDATE workflow_instance SET next_sequence=next_sequence+1,updated_utc_ms=?4 WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3;");
        defer self.finalize(instance_update);
        try self.bindText(instance_update, 1, tenant);
        try self.bindText(instance_update, 2, namespace);
        try self.bindId(instance_update, 3, workflow_id);
        try self.bindInt(instance_update, 4, self.clock.utcNow());
        _ = try self.step(instance_update);
        const wake = try self.prepare("INSERT INTO workflow_task(task_id,tenant,namespace,workflow_id,status,available_utc_ms) SELECT ?1,?2,?3,?4,'ready',?5 WHERE NOT EXISTS(SELECT 1 FROM workflow_task WHERE tenant=?2 AND namespace=?3 AND workflow_id=?4 AND status IN ('ready','claimed'));");
        defer self.finalize(wake);
        try self.bindId(wake, 1, derivedEventId(id, sequence + 1));
        try self.bindText(wake, 2, tenant);
        try self.bindText(wake, 3, namespace);
        try self.bindId(wake, 4, workflow_id);
        try self.bindInt(wake, 5, self.clock.utcNow());
        _ = try self.step(wake);
        try self.commit();
    }
    fn appendHistoryFact(self: *Store, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, event_id: core.StableId, kind: u32, schema: core.schema.SchemaKey, payload: []const u8, utc_ms: i64) Error!void {
        const seq = try self.prepare("SELECT next_sequence FROM workflow_instance WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3 AND status='running';");
        defer self.finalize(seq);
        try self.bindText(seq, 1, tenant);
        try self.bindText(seq, 2, namespace);
        try self.bindId(seq, 3, workflow_id);
        if (!try self.step(seq)) return error.NotFound;
        const sequence = self.columnInt(seq, 0);
        const history = try self.prepare("INSERT INTO workflow_history(tenant,namespace,workflow_id,sequence,event_id,kind,event_utc_ms,schema_id,schema_version,payload) VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10);");
        defer self.finalize(history);
        try self.bindText(history, 1, tenant);
        try self.bindText(history, 2, namespace);
        try self.bindId(history, 3, workflow_id);
        try self.bindInt(history, 4, sequence);
        try self.bindId(history, 5, event_id);
        try self.bindInt(history, 6, kind);
        try self.bindInt(history, 7, utc_ms);
        try self.bindInt(history, 8, @as(i64, @bitCast(schema.id)));
        try self.bindInt(history, 9, schema.version);
        try self.bindBlob(history, 10, payload);
        _ = try self.step(history);
        const update = try self.prepare("UPDATE workflow_instance SET next_sequence=next_sequence+1,updated_utc_ms=?4 WHERE tenant=?1 AND namespace=?2 AND workflow_id=?3;");
        defer self.finalize(update);
        try self.bindText(update, 1, tenant);
        try self.bindText(update, 2, namespace);
        try self.bindId(update, 3, workflow_id);
        try self.bindInt(update, 4, utc_ms);
        _ = try self.step(update);
    }
    fn applyMigration(self: *Store) Error!void {
        try self.exec("CREATE TABLE IF NOT EXISTS spindle_schema_migration(version INTEGER PRIMARY KEY,checksum INTEGER NOT NULL) STRICT;");
        try self.applyOneMigration(1, migration_sql);
        try self.applyOneMigration(2, migration_v2_sql);
        try self.applyOneMigration(3, migration_v3_sql);
    }
    fn recoverClaims(self: *Store) Error!store_health.Recovery {
        var recovery = store_health.Recovery{};
        try self.exec("UPDATE workflow_task SET status='ready',claimed_epoch=NULL WHERE status='claimed' AND EXISTS(SELECT 1 FROM workflow_instance i WHERE i.tenant=workflow_task.tenant AND i.namespace=workflow_task.namespace AND i.workflow_id=workflow_task.workflow_id AND i.status='running');");
        recovery.workflow_tasks = @intCast(c.sqlite3_changes(self.db));
        try self.exec("UPDATE activity_task SET status_v2='ready',claimed_epoch=NULL WHERE status_v2='claimed';");
        recovery.activities = @intCast(c.sqlite3_changes(self.db));
        try self.exec("UPDATE durable_timer SET status_v2='ready',claimed_epoch=NULL WHERE status_v2='claimed';");
        recovery.timers = @intCast(c.sqlite3_changes(self.db));
        try self.exec("UPDATE outbox SET status_v2='ready',claimed_epoch=NULL WHERE status_v2='claimed';");
        recovery.outbox = @intCast(c.sqlite3_changes(self.db));
        return recovery;
    }
    fn scalarU64(self: *Store, sql: [*:0]const u8) Error!u64 {
        const statement = try self.prepare(sql);
        defer self.finalize(statement);
        if (!try self.step(statement)) return 0;
        return @intCast(self.columnInt(statement, 0));
    }
    fn migrationHashesValid(self: *Store) bool {
        const first = self.migrationMatches(1, migration_sql) catch return false;
        const second = self.migrationMatches(2, migration_v2_sql) catch return false;
        const third = self.migrationMatches(3, migration_v3_sql) catch return false;
        return first and second and third;
    }
    fn migrationMatches(self: *Store, version: i64, sql: []const u8) Error!bool {
        const statement = try self.prepare("SELECT checksum FROM spindle_schema_migration WHERE version=?1;");
        defer self.finalize(statement);
        try self.bindInt(statement, 1, version);
        return try self.step(statement) and @as(u64, @bitCast(self.columnInt(statement, 0))) == core.hash.content(sql);
    }
    fn quickCheck(self: *Store) Error!bool {
        const statement = try self.prepare("PRAGMA quick_check;");
        defer self.finalize(statement);
        return try self.step(statement) and std.mem.eql(u8, self.columnText(statement, 0), "ok");
    }
    fn snapshotFailures(self: *Store) Error!u64 {
        const statement = try self.prepare("SELECT workflow_id,event_sequence,definition_version,state,checksum FROM workflow_snapshot;");
        defer self.finalize(statement);
        var failures: u64 = 0;
        while (try self.step(statement)) {
            const saved = snapshot.Snapshot{ .workflow_id = self.columnId(statement, 0), .event_sequence = @intCast(self.columnInt(statement, 1)), .definition_version = @intCast(self.columnInt(statement, 2)), .state = self.columnBlob(statement, 3), .checksum = @bitCast(self.columnInt(statement, 4)) };
            if (!snapshot.verify(saved)) failures += 1;
        }
        return failures;
    }
    fn applyOneMigration(self: *Store, version: i64, sql: []const u8) Error!void {
        const stmt = try self.prepare("SELECT checksum FROM spindle_schema_migration WHERE version=?1;");
        defer self.finalize(stmt);
        try self.bindInt(stmt, 1, version);
        if (try self.step(stmt)) {
            if (@as(u64, @bitCast(self.columnInt(stmt, 0))) != core.hash.content(sql)) return error.MigrationMismatch;
            return;
        }
        try self.exec(@ptrCast(sql.ptr));
        const record = try self.prepare("INSERT INTO spindle_schema_migration(version,checksum) VALUES(?1,?2);");
        defer self.finalize(record);
        try self.bindInt(record, 1, version);
        try self.bindInt(record, 2, @as(i64, @bitCast(core.hash.content(sql))));
        _ = try self.step(record);
    }
    fn metadataU64(self: *Store, key: []const u8) Error!u64 {
        const s = try self.prepare("SELECT value FROM metadata WHERE key=?1;");
        defer self.finalize(s);
        try self.bindText(s, 1, key);
        if (!try self.step(s)) return 0;
        return @bitCast(self.columnInt(s, 0));
    }
    fn setMetadataU64(self: *Store, key: []const u8, value: u64) Error!void {
        const s = try self.prepare("INSERT INTO metadata(key,value) VALUES(?1,?2) ON CONFLICT(key) DO UPDATE SET value=excluded.value;");
        defer self.finalize(s);
        try self.bindText(s, 1, key);
        try self.bindInt(s, 2, @as(i64, @bitCast(value)));
        _ = try self.step(s);
    }
    fn begin(self: *Store) Error!void {
        return self.exec("BEGIN IMMEDIATE;");
    }
    fn beginExclusive(self: *Store) Error!void {
        return self.exec("BEGIN EXCLUSIVE;");
    }
    fn commit(self: *Store) Error!void {
        return self.exec("COMMIT;");
    }
    fn rollback(self: *Store) void {
        self.exec("ROLLBACK;") catch {};
    }
    fn exec(self: *Store, sql: [*:0]const u8) Error!void {
        if (c.sqlite3_exec(self.db, sql, null, null, null) != c.SQLITE_OK) return map(c.sqlite3_errcode(self.db));
    }
    fn prepare(self: *Store, sql: [*:0]const u8) Error!*c.sqlite3_stmt {
        var s: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &s, null) != c.SQLITE_OK) return map(c.sqlite3_errcode(self.db));
        return s orelse error.DatabaseFailure;
    }
    fn finalize(_: *Store, s: *c.sqlite3_stmt) void {
        _ = c.sqlite3_finalize(s);
    }
    fn step(self: *Store, s: *c.sqlite3_stmt) Error!bool {
        const r = c.sqlite3_step(s);
        if (r == c.SQLITE_ROW) return true;
        if (r == c.SQLITE_DONE) return false;
        return map(c.sqlite3_errcode(self.db));
    }
    fn bindText(self: *Store, s: *c.sqlite3_stmt, n: c_int, v: []const u8) Error!void {
        if (c.sqlite3_bind_text(s, n, v.ptr, @intCast(v.len), sqlite_transient) != c.SQLITE_OK) return map(c.sqlite3_errcode(self.db));
    }
    fn bindBlob(self: *Store, s: *c.sqlite3_stmt, n: c_int, v: []const u8) Error!void {
        if (c.sqlite3_bind_blob(s, n, v.ptr, @intCast(v.len), sqlite_transient) != c.SQLITE_OK) return map(c.sqlite3_errcode(self.db));
    }
    fn bindInt(self: *Store, s: *c.sqlite3_stmt, n: c_int, v: anytype) Error!void {
        if (c.sqlite3_bind_int64(s, n, @intCast(v)) != c.SQLITE_OK) return map(c.sqlite3_errcode(self.db));
    }
    fn bindId(self: *Store, s: *c.sqlite3_stmt, n: c_int, v: core.StableId) Error!void {
        const b = v.toBytes();
        try self.bindBlob(s, n, &b);
    }
    fn columnInt(_: *Store, s: *c.sqlite3_stmt, n: c_int) i64 {
        return c.sqlite3_column_int64(s, n);
    }
    fn columnText(_: *Store, s: *c.sqlite3_stmt, n: c_int) []const u8 {
        const p = c.sqlite3_column_text(s, n);
        return p[0..@intCast(c.sqlite3_column_bytes(s, n))];
    }
    fn columnBlob(_: *Store, s: *c.sqlite3_stmt, n: c_int) []const u8 {
        const len: usize = @intCast(c.sqlite3_column_bytes(s, n));
        if (len == 0) return "";
        const p: [*]const u8 = @ptrCast(c.sqlite3_column_blob(s, n));
        return p[0..len];
    }
    fn columnId(self: *Store, s: *c.sqlite3_stmt, n: c_int) core.StableId {
        const b = self.columnBlob(s, n);
        var a: [16]u8 = undefined;
        @memcpy(&a, b[0..16]);
        return .fromBytes(a);
    }
};
fn parseStatus(v: []const u8) instance.Status {
    if (std.mem.eql(u8, v, "completed")) return .completed;
    if (std.mem.eql(u8, v, "failed")) return .failed;
    if (std.mem.eql(u8, v, "cancelled")) return .cancelled;
    return .running;
}
fn statusText(value: instance.Status) []const u8 {
    return switch (value) {
        .running => "running",
        .completed => "completed",
        .failed => "failed",
        .cancelled => "cancelled",
    };
}
fn derivedEventId(base: core.StableId, sequence: i64) core.StableId {
    var bytes = base.toBytes();
    const high = std.mem.readInt(u64, bytes[0..8], .big) ^ 0x6576_656e_742e_7766;
    const low = std.mem.readInt(u64, bytes[8..16], .big) ^ @as(u64, @bitCast(sequence));
    std.mem.writeInt(u64, bytes[0..8], high, .big);
    std.mem.writeInt(u64, bytes[8..16], low, .big);
    return .fromBytes(bytes);
}
fn map(code: c_int) Error {
    return switch (code & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
        c.SQLITE_FULL => error.DatabaseFull,
        c.SQLITE_READONLY => error.DatabaseReadOnly,
        c.SQLITE_IOERR => error.DatabaseIo,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB, c.SQLITE_SCHEMA => error.CorruptSchema,
        else => error.DatabaseFailure,
    };
}
fn quickCheckDb(db: *c.sqlite3) bool {
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &statement, null) != c.SQLITE_OK) return false;
    const value = statement orelse return false;
    defer _ = c.sqlite3_finalize(value);
    return c.sqlite3_step(value) == c.SQLITE_ROW and std.mem.eql(u8, c.sqlite3_column_text(value, 0)[0..@intCast(c.sqlite3_column_bytes(value, 0))], "ok");
}
fn validateDb(db: *c.sqlite3) bool {
    if (!quickCheckDb(db)) return false;
    if (!migrationDbMatches(db, 1, migration_sql) or !migrationDbMatches(db, 2, migration_v2_sql)) return false;
    const invariant_failures = rawScalar(
        db,
        "SELECT " ++
            "(SELECT count(*) FROM workflow_instance i WHERE i.next_sequence<>COALESCE((SELECT max(h.sequence)+1 FROM workflow_history h WHERE h.tenant=i.tenant AND h.namespace=i.namespace AND h.workflow_id=i.workflow_id),1) OR (SELECT count(*) FROM workflow_history h WHERE h.tenant=i.tenant AND h.namespace=i.namespace AND h.workflow_id=i.workflow_id)<>COALESCE((SELECT max(h.sequence) FROM workflow_history h WHERE h.tenant=i.tenant AND h.namespace=i.namespace AND h.workflow_id=i.workflow_id),0))+" ++
            "(SELECT count(*) FROM workflow_task t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL)+" ++
            "(SELECT count(*) FROM activity_task t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL)+" ++
            "(SELECT count(*) FROM durable_timer t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL)+" ++
            "(SELECT count(*) FROM outbox t LEFT JOIN workflow_instance i ON i.tenant=t.tenant AND i.namespace=t.namespace AND i.workflow_id=t.workflow_id WHERE i.workflow_id IS NULL);",
    ) orelse return false;
    if (invariant_failures != 0) return false;
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT workflow_id,event_sequence,definition_version,state,checksum FROM workflow_snapshot;", -1, &statement, null) != c.SQLITE_OK) return false;
    const rows = statement orelse return false;
    defer _ = c.sqlite3_finalize(rows);
    while (true) {
        const result = c.sqlite3_step(rows);
        if (result == c.SQLITE_DONE) return true;
        if (result != c.SQLITE_ROW) return false;
        const id_bytes = rawBlob(rows, 0);
        if (id_bytes.len != 16) return false;
        var id_array: [16]u8 = undefined;
        @memcpy(&id_array, id_bytes);
        const saved = snapshot.Snapshot{
            .workflow_id = .fromBytes(id_array),
            .event_sequence = @intCast(c.sqlite3_column_int64(rows, 1)),
            .definition_version = @intCast(c.sqlite3_column_int64(rows, 2)),
            .state = rawBlob(rows, 3),
            .checksum = @bitCast(c.sqlite3_column_int64(rows, 4)),
        };
        if (!snapshot.verify(saved)) return false;
    }
}
fn migrationDbMatches(db: *c.sqlite3, version: i64, sql: []const u8) bool {
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, "SELECT checksum FROM spindle_schema_migration WHERE version=?1;", -1, &statement, null) != c.SQLITE_OK) return false;
    const query = statement orelse return false;
    defer _ = c.sqlite3_finalize(query);
    if (c.sqlite3_bind_int64(query, 1, version) != c.SQLITE_OK) return false;
    return c.sqlite3_step(query) == c.SQLITE_ROW and @as(u64, @bitCast(c.sqlite3_column_int64(query, 0))) == core.hash.content(sql);
}
fn rawScalar(db: *c.sqlite3, sql: [*:0]const u8) ?u64 {
    var statement: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db, sql, -1, &statement, null) != c.SQLITE_OK) return null;
    const query = statement orelse return null;
    defer _ = c.sqlite3_finalize(query);
    if (c.sqlite3_step(query) != c.SQLITE_ROW) return null;
    return @intCast(c.sqlite3_column_int64(query, 0));
}
fn rawBlob(statement: *c.sqlite3_stmt, column: c_int) []const u8 {
    const len: usize = @intCast(c.sqlite3_column_bytes(statement, column));
    if (len == 0) return "";
    const bytes: [*]const u8 = @ptrCast(c.sqlite3_column_blob(statement, column));
    return bytes[0..len];
}
fn validateFile(allocator: std.mem.Allocator, path: []const u8) bool {
    const zpath = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(zpath);
    var raw: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(zpath.ptr, &raw, c.SQLITE_OPEN_READONLY | c.SQLITE_OPEN_FULLMUTEX, null) != c.SQLITE_OK) {
        if (raw) |handle| _ = c.sqlite3_close_v2(handle);
        return false;
    }
    const db = raw orelse return false;
    defer _ = c.sqlite3_close_v2(db);
    return validateDb(db);
}
fn cancelled(options: store_health.Maintenance) bool {
    return if (options.cancelled) |check| check(options.cancellation_context) else false;
}
fn fileBytes(path: []const u8) u64 {
    const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return 0;
    return @intCast(stat.size);
}
fn initError(err: Error) Error {
    return if (err == error.DatabaseBusy) error.WorkflowStoreInUse else err;
}
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
