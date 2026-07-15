const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});
const core = @import("../core/root.zig");
const persistence = @import("persistence.zig");

pub const max_payload_bytes: usize = 16 * 1024 * 1024;
pub const Error = error{ ConnectFailed, QueryFailed, TransactionFailed, InvalidConfiguration, PayloadTooLarge, PoolExhausted, CancelFailed } || std.mem.Allocator.Error;
pub const ClaimedTask = struct { task_id: core.StableId, workflow_id: core.StableId, lease_epoch: u64 };

/// A libpq connection. It is single-owner; construct one per worker/pool slot.
pub const Connection = struct {
    handle: *c.PGconn,
    pub fn init(dsn: [:0]const u8) Error!Connection {
        const h = c.PQconnectdb(dsn.ptr);
        if (c.PQstatus(h) != c.CONNECTION_OK) {
            c.PQfinish(h);
            return error.ConnectFailed;
        }
        return .{ .handle = h };
    }
    pub fn deinit(self: *Connection) void {
        c.PQfinish(self.handle);
        self.* = undefined;
    }
    /// Requests cancellation of the connection's currently executing command. It is safe to call from another thread.
    pub fn cancel(self: *Connection) Error!void {
        const request = c.PQgetCancel(self.handle) orelse return error.CancelFailed;
        defer c.PQfreeCancel(request);
        var message: [256:0]u8 = undefined;
        if (c.PQcancel(request, &message, message.len) == 0) return error.CancelFailed;
    }
    fn exec(self: *Connection, sql: [:0]const u8) Error!void {
        const r = c.PQexec(self.handle, sql.ptr) orelse return error.QueryFailed;
        defer c.PQclear(r);
        if (c.PQresultStatus(r) != c.PGRES_COMMAND_OK and c.PQresultStatus(r) != c.PGRES_TUPLES_OK) return error.QueryFailed;
    }
    fn execParams(self: *Connection, sql: [:0]const u8, values: []const []const u8, formats: []const c_int) Error!c_int {
        if (values.len != formats.len or values.len > 16) return error.QueryFailed;
        var raw: [16][*c]const u8 = undefined;
        var lengths: [16]c_int = undefined;
        for (values, 0..) |value, index| {
            raw[index] = value.ptr;
            lengths[index] = @intCast(value.len);
        }
        const result = c.PQexecParams(self.handle, sql.ptr, @intCast(values.len), null, &raw, &lengths, formats.ptr, 0) orelse return error.QueryFailed;
        defer c.PQclear(result);
        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) return error.QueryFailed;
        if (status == c.PGRES_TUPLES_OK) return c.PQntuples(result);
        const affected = std.mem.span(c.PQcmdTuples(result));
        return std.fmt.parseInt(c_int, affected, 10) catch 0;
    }
    /// Applies versioned SQL files under an advisory lock; modified applied files are rejected by checksum.
    pub fn migrate(self: *Connection) Error!void {
        try self.exec("BEGIN");
        errdefer self.exec("ROLLBACK") catch {};
        try self.exec("SELECT pg_advisory_xact_lock(7319616)");
        try self.exec("CREATE TABLE IF NOT EXISTS spindle_schema_migration (version bigint PRIMARY KEY, checksum text NOT NULL, applied_at timestamptz NOT NULL DEFAULT clock_timestamp())");
        const sql = @embedFile("../../../db/migrations/0001_workflow.sql");
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(sql, &digest, .{});
        var hex: [64]u8 = undefined;
        _ = std.fmt.bufPrint(&hex, "{x}", .{digest}) catch unreachable;
        var query: [512]u8 = undefined;
        const check = std.fmt.bufPrintZ(&query, "SELECT checksum FROM spindle_schema_migration WHERE version=1", .{}) catch return error.QueryFailed;
        const existing = c.PQexec(self.handle, check.ptr) orelse return error.QueryFailed;
        defer c.PQclear(existing);
        if (c.PQntuples(existing) == 1) {
            const actual = std.mem.span(c.PQgetvalue(existing, 0, 0));
            if (!std.mem.eql(u8, actual, &hex)) return error.InvalidConfiguration;
            try self.exec("COMMIT");
            return;
        }
        var statement_iter = std.mem.splitSequence(u8, sql, ";\n");
        while (statement_iter.next()) |statement| {
            if (std.mem.trim(u8, statement, " \t\r\n").len == 0) continue;
            var z: [32768]u8 = undefined;
            if (statement.len + 1 > z.len) return error.QueryFailed;
            @memcpy(z[0..statement.len], statement);
            z[statement.len] = 0;
            try self.exec(z[0..statement.len :0]);
        }
        const insert = std.fmt.bufPrintZ(&query, "INSERT INTO spindle_schema_migration(version, checksum) VALUES (1, '{s}')", .{hex}) catch return error.QueryFailed;
        try self.exec(insert);
        try self.exec("COMMIT");
    }
    /// Commits a transition in one PostgreSQL transaction. The explicit row locks are the optimistic/version and lease fence.
    pub fn commitWorkflowTaskTransition(self: *Connection, input: persistence.CommitInput) persistence.Error!void {
        if (input.new_state.len > max_payload_bytes) return error.PayloadTooLarge;
        self.exec("BEGIN") catch return error.DatabaseFailure;
        errdefer self.exec("ROLLBACK") catch {};
        var sql: [2048]u8 = undefined;
        const wid = input.workflow_id.toBytes();
        const tid = input.task_id.toBytes();
        // UUIDs are passed as canonical text only after StableId formatting, never interpolated caller data.
        var wid_text: [36]u8 = undefined;
        var tid_text: [36]u8 = undefined;
        var w = std.Io.Writer.fixed(&wid_text);
        input.workflow_id.format(&w) catch return error.DatabaseFailure;
        var t = std.Io.Writer.fixed(&tid_text);
        input.task_id.format(&t) catch return error.DatabaseFailure;
        _ = wid;
        _ = tid;
        const fence = std.fmt.bufPrintZ(&sql, "UPDATE workflow_task SET status='done' WHERE task_id='{s}'::uuid AND status='leased' AND lease_epoch={d};", .{ tid_text, input.lease_epoch }) catch return error.DatabaseFailure;
        const result = c.PQexec(self.handle, fence.ptr) orelse return error.DatabaseFailure;
        defer c.PQclear(result);
        if (c.PQcmdTuples(result)[0] != '1') return error.LeaseLost;
        const update = std.fmt.bufPrintZ(&sql, "UPDATE workflow_instance SET state_version=state_version+1, state=$1, status=$2, updated_at=clock_timestamp() WHERE workflow_id='{s}'::uuid AND state_version={d};", .{ wid_text, input.expected_state_version }) catch return error.DatabaseFailure;
        const values = [_]?[*:0]const u8{ input.new_state.ptr, @tagName(input.new_status).ptr };
        const lengths = [_]c_int{ @intCast(input.new_state.len), @intCast(@tagName(input.new_status).len) };
        const formats = [_]c_int{ 1, 0 };
        const update_result = c.PQexecParams(self.handle, update.ptr, 2, null, &values, &lengths, &formats, 0) orelse return error.DatabaseFailure;
        defer c.PQclear(update_result);
        if (c.PQcmdTuples(update_result)[0] != '1') return error.Conflict;
        for (input.events) |append| {
            if (append.value.payload.bytes.len > max_payload_bytes) return error.PayloadTooLarge;
            var eid_text: [36]u8 = undefined;
            var ewriter = std.Io.Writer.fixed(&eid_text);
            append.event_id.format(&ewriter) catch return error.DatabaseFailure;
            var sequence: [32]u8 = undefined;
            var kind: [16]u8 = undefined;
            var utc_ms: [32]u8 = undefined;
            var schema_id: [32]u8 = undefined;
            var schema_version: [16]u8 = undefined;
            const event_sql = "INSERT INTO workflow_history(tenant,namespace,workflow_id,sequence,event_id,kind,event_utc_ms,schema_id,schema_version,payload) VALUES($1,$2,$3::uuid,$4::bigint,$5::uuid,$6::int,$7::bigint,$8::bigint,$9::int,$10) ON CONFLICT(event_id) DO UPDATE SET event_id=EXCLUDED.event_id WHERE workflow_history.tenant=EXCLUDED.tenant AND workflow_history.namespace=EXCLUDED.namespace AND workflow_history.workflow_id=EXCLUDED.workflow_id AND workflow_history.sequence=EXCLUDED.sequence AND workflow_history.kind=EXCLUDED.kind AND workflow_history.event_utc_ms=EXCLUDED.event_utc_ms AND workflow_history.schema_id=EXCLUDED.schema_id AND workflow_history.schema_version=EXCLUDED.schema_version AND workflow_history.payload=EXCLUDED.payload RETURNING event_id";
            const values = [_][]const u8{ input.tenant, input.namespace, &wid_text, std.fmt.bufPrint(&sequence, "{d}", .{append.value.sequence}) catch return error.DatabaseFailure, &eid_text, std.fmt.bufPrint(&kind, "{d}", .{append.value.kind}) catch return error.DatabaseFailure, std.fmt.bufPrint(&utc_ms, "{d}", .{append.value.utc_ms}) catch return error.DatabaseFailure, std.fmt.bufPrint(&schema_id, "{d}", .{append.value.payload.schema.id}) catch return error.DatabaseFailure, std.fmt.bufPrint(&schema_version, "{d}", .{append.value.payload.schema.version}) catch return error.DatabaseFailure, append.value.payload.bytes };
            const formats = [_]c_int{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
            if ((self.execParams(event_sql, &values, &formats) catch return error.DatabaseFailure) != 1) return error.DuplicateEventConflict;
        }
        if (input.optional_snapshot) |value| {
            if (value.state.len > max_payload_bytes or !@import("snapshot.zig").verify(value)) return error.DatabaseFailure;
            var sequence: [32]u8 = undefined;
            var version: [16]u8 = undefined;
            var checksum: [32]u8 = undefined;
            const snapshot_sql = "INSERT INTO workflow_snapshot(tenant,namespace,workflow_id,event_sequence,definition_version,state,checksum) VALUES($1,$2,$3::uuid,$4::bigint,$5::int,$6,$7::bigint)";
            const values = [_][]const u8{ input.tenant, input.namespace, &wid_text, std.fmt.bufPrint(&sequence, "{d}", .{value.event_sequence}) catch return error.DatabaseFailure, std.fmt.bufPrint(&version, "{d}", .{value.definition_version}) catch return error.DatabaseFailure, value.state, std.fmt.bufPrint(&checksum, "{d}", .{value.checksum}) catch return error.DatabaseFailure };
            const formats = [_]c_int{ 0, 0, 0, 0, 0, 1, 0 };
            _ = self.execParams(snapshot_sql, &values, &formats) catch return error.DatabaseFailure;
        }
        if (input.scheduled.next_task) |next| try self.insertWorkflowTask(input.tenant, input.namespace, input.workflow_id, next.task_id);
        for (input.scheduled.activities) |activity| try self.insertActivity(input.tenant, input.namespace, input.workflow_id, activity);
        for (input.scheduled.timers) |timer| try self.insertTimer(input.tenant, input.namespace, input.workflow_id, timer);
        for (input.scheduled.outbox) |message| try self.insertOutbox(input.tenant, input.namespace, input.workflow_id, message);
        self.exec("COMMIT") catch return error.DatabaseFailure;
    }
    fn insertWorkflowTask(self: *Connection, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, task_id: core.StableId) persistence.Error!void {
        var workflow: [36]u8 = undefined;
        var task: [36]u8 = undefined;
        var a = std.Io.Writer.fixed(&workflow);
        var b = std.Io.Writer.fixed(&task);
        workflow_id.format(&a) catch return error.DatabaseFailure;
        task_id.format(&b) catch return error.DatabaseFailure;
        const values = [_][]const u8{ tenant, namespace, &workflow, &task };
        const formats = [_]c_int{ 0, 0, 0, 0 };
        _ = self.execParams("INSERT INTO workflow_task(task_id,tenant,namespace,workflow_id) VALUES($4::uuid,$1,$2,$3::uuid)", &values, &formats) catch return error.DatabaseFailure;
    }
    fn insertActivity(self: *Connection, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, item: persistence.ActivityTask) persistence.Error!void {
        if (item.payload.len > max_payload_bytes) return error.PayloadTooLarge;
        var workflow: [36]u8 = undefined;
        var task: [36]u8 = undefined;
        var sequence: [32]u8 = undefined;
        var a = std.Io.Writer.fixed(&workflow);
        var b = std.Io.Writer.fixed(&task);
        workflow_id.format(&a) catch return error.DatabaseFailure;
        item.task_id.format(&b) catch return error.DatabaseFailure;
        const values = [_][]const u8{ tenant, namespace, &workflow, &task, std.fmt.bufPrint(&sequence, "{d}", .{item.command_sequence}) catch return error.DatabaseFailure, item.payload };
        const formats = [_]c_int{ 0, 0, 0, 0, 0, 1 };
        _ = self.execParams("INSERT INTO activity_task(task_id,tenant,namespace,workflow_id,command_sequence,payload) VALUES($4::uuid,$1,$2,$3::uuid,$5::bigint,$6)", &values, &formats) catch return error.DatabaseFailure;
    }
    fn insertTimer(self: *Connection, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, item: persistence.Timer) persistence.Error!void {
        if (item.payload.len > max_payload_bytes) return error.PayloadTooLarge;
        var workflow: [36]u8 = undefined;
        var timer: [36]u8 = undefined;
        var fire_at: [32]u8 = undefined;
        var a = std.Io.Writer.fixed(&workflow);
        var b = std.Io.Writer.fixed(&timer);
        workflow_id.format(&a) catch return error.DatabaseFailure;
        item.timer_id.format(&b) catch return error.DatabaseFailure;
        const values = [_][]const u8{ tenant, namespace, &workflow, &timer, std.fmt.bufPrint(&fire_at, "{d}", .{item.fire_at_utc_ms}) catch return error.DatabaseFailure, item.payload };
        const formats = [_]c_int{ 0, 0, 0, 0, 0, 1 };
        _ = self.execParams("INSERT INTO durable_timer(timer_id,tenant,namespace,workflow_id,fire_at_utc_ms,payload) VALUES($4::uuid,$1,$2,$3::uuid,$5::bigint,$6)", &values, &formats) catch return error.DatabaseFailure;
    }
    fn insertOutbox(self: *Connection, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, item: persistence.OutboxMessage) persistence.Error!void {
        if (item.payload.len > max_payload_bytes) return error.PayloadTooLarge;
        var workflow: [36]u8 = undefined;
        var message: [36]u8 = undefined;
        var a = std.Io.Writer.fixed(&workflow);
        var b = std.Io.Writer.fixed(&message);
        workflow_id.format(&a) catch return error.DatabaseFailure;
        item.message_id.format(&b) catch return error.DatabaseFailure;
        const values = [_][]const u8{ tenant, namespace, &workflow, &message, item.payload };
        const formats = [_]c_int{ 0, 0, 0, 0, 1 };
        _ = self.execParams("INSERT INTO outbox(message_id,tenant,namespace,workflow_id,payload) VALUES($4::uuid,$1,$2,$3::uuid,$5)", &values, &formats) catch return error.DatabaseFailure;
    }

    /// Atomically claims one ready or expired task. `clock_timestamp()` keeps lease correctness on server time.
    pub fn claimWorkflowTask(self: *Connection, tenant: []const u8, namespace: []const u8, worker: []const u8, lease_ms: u64) Error!?ClaimedTask {
        var duration: [32]u8 = undefined;
        const values = [_][]const u8{ tenant, namespace, worker, std.fmt.bufPrint(&duration, "{d}", .{lease_ms}) catch return error.QueryFailed };
        const formats = [_]c_int{ 0, 0, 0, 0 };
        var raw: [4][*c]const u8 = undefined;
        var lengths: [4]c_int = undefined;
        for (values, 0..) |value, index| {
            raw[index] = value.ptr;
            lengths[index] = @intCast(value.len);
        }
        const sql = "WITH candidate AS (SELECT task_id FROM workflow_task WHERE tenant=$1 AND namespace=$2 AND (status='ready' AND available_at <= clock_timestamp() OR status='leased' AND lease_expires_at <= clock_timestamp()) ORDER BY available_at FOR UPDATE SKIP LOCKED LIMIT 1) UPDATE workflow_task t SET status='leased',lease_owner=$3,lease_epoch=t.lease_epoch+1,lease_expires_at=clock_timestamp()+($4::bigint * interval '1 millisecond') FROM candidate WHERE t.task_id=candidate.task_id RETURNING t.task_id::text,t.workflow_id::text,t.lease_epoch";
        const result = c.PQexecParams(self.handle, sql, 4, null, &raw, &lengths, &formats, 0) orelse return error.QueryFailed;
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) return error.QueryFailed;
        if (c.PQntuples(result) == 0) return null;
        const task = core.StableId.parse(std.mem.span(c.PQgetvalue(result, 0, 0))) catch return error.QueryFailed;
        const workflow = core.StableId.parse(std.mem.span(c.PQgetvalue(result, 0, 1))) catch return error.QueryFailed;
        const epoch = std.fmt.parseInt(u64, std.mem.span(c.PQgetvalue(result, 0, 2)), 10) catch return error.QueryFailed;
        return .{ .task_id = task, .workflow_id = workflow, .lease_epoch = epoch };
    }

    /// Records an inbound message once. The caller's business mutation must share this transaction boundary.
    pub fn recordInbox(self: *Connection, tenant: []const u8, namespace: []const u8, workflow_id: core.StableId, message_id: core.StableId, payload: []const u8) Error!bool {
        if (payload.len > max_payload_bytes) return error.PayloadTooLarge;
        var workflow: [36]u8 = undefined;
        var message: [36]u8 = undefined;
        var a = std.Io.Writer.fixed(&workflow);
        var b = std.Io.Writer.fixed(&message);
        workflow_id.format(&a) catch return error.QueryFailed;
        message_id.format(&b) catch return error.QueryFailed;
        const values = [_][]const u8{ tenant, namespace, &workflow, &message, payload };
        const formats = [_]c_int{ 0, 0, 0, 0, 1 };
        try self.exec("BEGIN");
        errdefer self.exec("ROLLBACK") catch {};
        const inserted = self.execParams("INSERT INTO inbox(tenant,namespace,message_id,workflow_id,payload) VALUES($1,$2,$4::uuid,$3::uuid,$5) ON CONFLICT DO NOTHING", &values, &formats) catch return error.QueryFailed;
        // SELECT confirms whether an inbox row exists; duplicate delivery is intentionally successful and side-effect free.
        try self.exec("COMMIT");
        return inserted == 1;
    }

    /// Marks a claimed outbox record published only when the caller still owns its epoch.
    pub fn markOutboxPublished(self: *Connection, message_id: core.StableId, lease_epoch: u64) Error!bool {
        var message: [36]u8 = undefined;
        var epoch: [32]u8 = undefined;
        var writer = std.Io.Writer.fixed(&message);
        message_id.format(&writer) catch return error.QueryFailed;
        const values = [_][]const u8{ &message, std.fmt.bufPrint(&epoch, "{d}", .{lease_epoch}) catch return error.QueryFailed };
        const formats = [_]c_int{ 0, 0 };
        const count = try self.execParams("UPDATE outbox SET published_at=clock_timestamp() WHERE message_id=$1::uuid AND lease_epoch=$2::bigint AND published_at IS NULL", &values, &formats);
        return count == 1;
    }
};

/// Bounded pool of single-owner libpq connections. A lease must be returned before pool deinit.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    connections: []Connection,
    in_use: []bool,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, dsn: [:0]const u8, capacity: usize) Error!Pool {
        if (capacity == 0) return error.InvalidConfiguration;
        const connections = try allocator.alloc(Connection, capacity);
        errdefer allocator.free(connections);
        const in_use = try allocator.alloc(bool, capacity);
        errdefer allocator.free(in_use);
        @memset(in_use, false);
        var initialized: usize = 0;
        errdefer for (connections[0..initialized]) |*connection| connection.deinit();
        while (initialized < capacity) : (initialized += 1) connections[initialized] = try Connection.init(dsn);
        return .{ .allocator = allocator, .connections = connections, .in_use = in_use };
    }
    pub fn deinit(self: *Pool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.in_use) |busy| std.debug.assert(!busy);
        for (self.connections) |*connection| connection.deinit();
        self.allocator.free(self.connections);
        self.allocator.free(self.in_use);
        self.* = undefined;
    }
    /// Acquires immediately. Callers use their injected deadline to retry or cancel rather than blocking an executor thread.
    pub fn tryAcquire(self: *Pool) Error!Lease {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.in_use, 0..) |busy, index| if (!busy) {
            self.in_use[index] = true;
            return .{ .pool = self, .index = index };
        };
        return error.PoolExhausted;
    }
    pub const Lease = struct {
        pool: *Pool,
        index: usize,
        pub fn connection(self: *Lease) *Connection {
            return &self.pool.connections[self.index];
        }
        pub fn release(self: *Lease) void {
            self.pool.mutex.lock();
            defer self.pool.mutex.unlock();
            std.debug.assert(self.pool.in_use[self.index]);
            self.pool.in_use[self.index] = false;
            self.* = undefined;
        }
    };
};
