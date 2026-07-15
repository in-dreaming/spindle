const std = @import("std");
const core = @import("../core/root.zig");
const definition = @import("definition.zig");
const event = @import("event.zig");
const sqlite = @import("sqlite.zig");

pub const Action = enum { start, signal, cancel, get_instance };
pub const AuthHook = *const fn (?*anyopaque, []const u8, []const u8, Action, ?core.StableId) bool;
pub const SchemaHook = *const fn (?*anyopaque, []const u8, []const u8, core.schema.SchemaKey) bool;
pub const Error = error{ Unauthorized, IdempotencyConflict, NotFound, DatabaseFailure, PayloadTooLarge, QuotaExceeded, SchemaNotAllowed };
pub const IdSource = struct {
    context: *anyopaque,
    next_fn: *const fn (*anyopaque) core.StableId,
    pub fn next(self: IdSource) core.StableId {
        return self.next_fn(self.context);
    }
};
pub const StartRequest = struct { definition_name: []const u8, definition: definition.Definition, input: event.Payload, tenant: []const u8, namespace: []const u8, idempotency_key: []const u8, utc_ms: i64 };
pub const SignalRequest = struct { workflow_id: core.StableId, signal_name: []const u8, payload: event.Payload, message_id: core.StableId, tenant: []const u8, namespace: []const u8, utc_ms: i64 };
pub const CancelRequest = struct { workflow_id: core.StableId, message_id: core.StableId, tenant: []const u8, namespace: []const u8, utc_ms: i64 };

/// The only public mutation/query facade. Authorization runs before every SQLite transaction.
pub const Client = struct {
    store: *sqlite.Store,
    auth_context: ?*anyopaque,
    auth: AuthHook,
    ids: IdSource,
    schema_context: ?*anyopaque = null,
    schema_allowed: SchemaHook = allowSchema,
    max_workflows_per_namespace: u64 = 100_000,
    pub fn start(self: Client, r: StartRequest) Error!core.StableId {
        if (!self.auth(self.auth_context, r.tenant, r.namespace, .start, null)) return error.Unauthorized;
        if (!self.schema_allowed(self.schema_context, r.tenant, r.namespace, r.input.schema)) return error.SchemaNotAllowed;
        const instance_count = self.store.instanceCount(r.tenant, r.namespace) catch return error.DatabaseFailure;
        if (instance_count >= self.max_workflows_per_namespace) return error.QuotaExceeded;
        const utc_ms = self.store.clock.utcNow();
        return self.store.start(.{ .workflow_id = self.ids.next(), .task_id = self.ids.next(), .event_id = self.ids.next(), .tenant = r.tenant, .namespace = r.namespace, .idempotency_key = r.idempotency_key, .request_hash = @bitCast(hash(r)), .definition_id = r.definition.id, .definition_version = r.definition.version, .schema = r.input.schema, .payload = r.input.bytes, .utc_ms = utc_ms }) catch |e| switch (e) {
            error.IdempotencyConflict => error.IdempotencyConflict,
            error.PayloadTooLarge => error.PayloadTooLarge,
            else => error.DatabaseFailure,
        };
    }
    pub fn signal(self: Client, r: SignalRequest) Error!void {
        if (!self.auth(self.auth_context, r.tenant, r.namespace, .signal, r.workflow_id)) return error.Unauthorized;
        if (!self.schema_allowed(self.schema_context, r.tenant, r.namespace, r.payload.schema)) return error.SchemaNotAllowed;
        const utc_ms = self.store.clock.utcNow();
        return self.store.appendInbox(.{ .task_id = self.ids.next(), .event_id = self.ids.next(), .message_id = r.message_id, .workflow_id = r.workflow_id, .tenant = r.tenant, .namespace = r.namespace, .kind = event.Kind.signal_received, .schema = r.payload.schema, .payload = r.payload.bytes, .utc_ms = utc_ms }) catch |e| switch (e) {
            error.PayloadTooLarge => error.PayloadTooLarge,
            else => error.DatabaseFailure,
        };
    }
    pub fn requestCancel(self: Client, r: CancelRequest) Error!void {
        if (!self.auth(self.auth_context, r.tenant, r.namespace, .cancel, r.workflow_id)) return error.Unauthorized;
        const utc_ms = self.store.clock.utcNow();
        return self.store.appendInbox(.{ .task_id = self.ids.next(), .event_id = self.ids.next(), .message_id = r.message_id, .workflow_id = r.workflow_id, .tenant = r.tenant, .namespace = r.namespace, .kind = event.Kind.cancellation_requested, .schema = .{ .id = 0, .version = 1 }, .payload = "", .utc_ms = utc_ms }) catch |e| switch (e) {
            error.NotFound => error.NotFound,
            else => error.DatabaseFailure,
        };
    }
    pub fn getInstance(self: Client, tenant: []const u8, namespace: []const u8, id: core.StableId) Error!sqlite.InstanceRecord {
        if (!self.auth(self.auth_context, tenant, namespace, .get_instance, id)) return error.Unauthorized;
        return self.store.getInstance(tenant, namespace, id) catch |e| switch (e) {
            error.NotFound => error.NotFound,
            else => error.DatabaseFailure,
        };
    }
};
fn hash(r: StartRequest) u64 {
    var header: [36]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], r.definition.id, .big);
    std.mem.writeInt(u32, header[8..12], r.definition.version, .big);
    std.mem.writeInt(u64, header[12..20], r.input.schema.id, .big);
    std.mem.writeInt(u32, header[20..24], r.input.schema.version, .big);
    std.mem.writeInt(u32, header[24..28], @intCast(r.definition_name.len), .big);
    std.mem.writeInt(u64, header[28..36], r.input.bytes.len, .big);
    var hasher = std.hash.Fnv1a_64.init();
    hasher.update(&header);
    hasher.update(r.definition_name);
    hasher.update(r.input.bytes);
    return hasher.final();
}
pub fn allowAll(_: ?*anyopaque, _: []const u8, _: []const u8, _: Action, _: ?core.StableId) bool {
    return true;
}
pub fn denyAll(_: ?*anyopaque, _: []const u8, _: []const u8, _: Action, _: ?core.StableId) bool {
    return false;
}
pub fn allowSchema(_: ?*anyopaque, _: []const u8, _: []const u8, _: core.schema.SchemaKey) bool {
    return true;
}
