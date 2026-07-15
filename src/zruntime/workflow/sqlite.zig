const std = @import("std");
const core = @import("../core/root.zig");
const executor = @import("../executor/root.zig");
const event = @import("event.zig");
const instance = @import("instance.zig");
const persistence = @import("persistence.zig");
const snapshot = @import("snapshot.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});
const sqlite_transient: c.sqlite3_destructor_type = @ptrFromInt(std.math.maxInt(usize));

pub const max_payload_bytes: usize = 1024 * 1024;
pub const Error = error{ WorkflowStoreInUse, MigrationMismatch, CorruptSchema, PayloadTooLarge, IdempotencyConflict, NotFound, StaleRuntimeEpoch, Conflict, DatabaseBusy, DatabaseFull, DatabaseIo, DatabaseFailure };
pub const InstanceRecord = struct { id: core.StableId, definition_id: u64, definition_version: u32, status: instance.Status, state_version: u64, state: []u8 };
pub const Claim = struct { task_id: core.StableId, workflow_id: core.StableId, state_version: u64, definition_id: u64, definition_version: u32, runtime_epoch: u64 };
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

/// One SQLite connection, serialized by this store. It owns the process-local SQLite store lock.
pub const Store = struct {
    allocator: std.mem.Allocator,
    db: *c.sqlite3,
    clock: core.Clock,
    mutex: std.atomic.Mutex = .unlocked,
    runtime_epoch: u64,
    dispatcher: executor.BlockingExecutor,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, clock: core.Clock) Error!Store {
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
        var self = Store{ .allocator = allocator, .db = db, .clock = clock, .runtime_epoch = 0, .dispatcher = dispatcher };
        errdefer self.deinit();
        try self.invoke(Store.initialize, .{});
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
        const previous = try self.metadataU64("runtime_epoch");
        self.runtime_epoch = previous + 1;
        try self.setMetadataU64("runtime_epoch", self.runtime_epoch);
        try self.commit();
    }

    pub fn deinit(self: *Store) void {
        self.invoke(Store.close, .{}) catch {};
        self.dispatcher.deinit();
        self.* = undefined;
    }
    fn close(self: *Store) Error!void {
        if (c.sqlite3_close_v2(self.db) != c.SQLITE_OK) return error.DatabaseFailure;
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
            const stmt = try self.prepare("INSERT OR IGNORE INTO activity_task(task_id,tenant,namespace,workflow_id,command_sequence,payload) VALUES(?1,?2,?3,?4,?5,?6);");
            defer self.finalize(stmt);
            try self.bindId(stmt, 1, activity.task_id);
            try self.bindText(stmt, 2, tenant);
            try self.bindText(stmt, 3, namespace);
            try self.bindId(stmt, 4, workflow_id);
            try self.bindInt(stmt, 5, activity.command_sequence);
            try self.bindBlob(stmt, 6, activity.payload);
            _ = try self.step(stmt);
        }
        for (scheduled.timers) |timer| {
            if (timer.payload.len > max_payload_bytes) return error.PayloadTooLarge;
            const stmt = try self.prepare("INSERT OR IGNORE INTO durable_timer(timer_id,tenant,namespace,workflow_id,fire_at_utc_ms,payload) VALUES(?1,?2,?3,?4,?5,?6);");
            defer self.finalize(stmt);
            try self.bindId(stmt, 1, timer.timer_id);
            try self.bindText(stmt, 2, tenant);
            try self.bindText(stmt, 3, namespace);
            try self.bindId(stmt, 4, workflow_id);
            try self.bindInt(stmt, 5, timer.fire_at_utc_ms);
            try self.bindBlob(stmt, 6, timer.payload);
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
    }
    fn applyMigration(self: *Store) Error!void {
        try self.exec("CREATE TABLE IF NOT EXISTS spindle_schema_migration(version INTEGER PRIMARY KEY,checksum INTEGER NOT NULL) STRICT;");
        const stmt = try self.prepare("SELECT checksum FROM spindle_schema_migration WHERE version=1;");
        defer self.finalize(stmt);
        if (try self.step(stmt)) {
            if (@as(u64, @bitCast(self.columnInt(stmt, 0))) != core.hash.content(migration_sql)) return error.MigrationMismatch;
            return;
        }
        try self.exec(migration_sql);
        const record = try self.prepare("INSERT INTO spindle_schema_migration(version,checksum) VALUES(1,?1);");
        defer self.finalize(record);
        try self.bindInt(record, 1, @as(i64, @bitCast(core.hash.content(migration_sql))));
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
fn map(code: c_int) Error {
    return switch (code & 0xff) {
        c.SQLITE_BUSY, c.SQLITE_LOCKED => error.DatabaseBusy,
        c.SQLITE_FULL => error.DatabaseFull,
        c.SQLITE_IOERR => error.DatabaseIo,
        c.SQLITE_CORRUPT, c.SQLITE_NOTADB, c.SQLITE_SCHEMA => error.CorruptSchema,
        else => error.DatabaseFailure,
    };
}
fn initError(err: Error) Error {
    return if (err == error.DatabaseBusy) error.WorkflowStoreInUse else err;
}
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
