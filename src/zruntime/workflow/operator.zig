const std = @import("std");
const core = @import("../core/root.zig");
const migration = @import("migration.zig");
const sqlite = @import("sqlite.zig");

pub const Role = enum { viewer, operator, admin };
pub const Principal = struct { name: []const u8, tenant: []const u8, namespace: []const u8, role: Role };
pub const Limits = struct { max_history_events: usize = 100_000, max_pending: u64 = 1_000_000 };
pub const Mutation = struct { workflow_id: core.StableId, tenant: []const u8, namespace: []const u8, reason: []const u8, idempotency_key: []const u8 };
pub const Migration = struct { mutation: Mutation, target_version: u32, target_hash: u64, steps: []const migration.Step };
pub const Error = sqlite.Error || std.mem.Allocator.Error || error{ReplayLimitExceeded};

/// Principal-bound operator API. Tenant and namespace scope cannot be widened per request.
pub const Client = struct {
    store: *sqlite.Store,
    principal: Principal,
    ids: @import("client.zig").IdSource,
    limits: Limits = .{},

    pub fn inspect(self: Client, tenant: []const u8, namespace: []const u8, id: core.StableId) Error!sqlite.InstanceRecord {
        if (!self.inScope(tenant, namespace)) return error.Unauthorized;
        return self.store.getInstance(tenant, namespace, id);
    }
    pub fn history(self: Client, allocator: std.mem.Allocator, tenant: []const u8, namespace: []const u8, id: core.StableId) Error![]sqlite.HistoryRecord {
        if (!self.inScope(tenant, namespace)) return error.Unauthorized;
        const records = try self.store.readHistory(allocator, tenant, namespace, id);
        if (records.len > self.limits.max_history_events) {
            for (records) |record| allocator.free(record.payload);
            allocator.free(records);
            return error.ReplayLimitExceeded;
        }
        return records;
    }
    pub fn pending(self: Client) Error!sqlite.Pending {
        const value = try self.store.pending(self.principal.tenant, self.principal.namespace);
        if (value.workflow_tasks + value.activities + value.timers + value.outbox > self.limits.max_pending) return error.QuotaExceeded;
        return value;
    }
    pub fn cancel(self: Client, value: Mutation) Error!void {
        const m = self.storeMutation(value, self.canOperate(), "cancel");
        return self.store.operatorCancel(m, self.ids.next(), self.ids.next());
    }
    pub fn retry(self: Client, value: Mutation) Error!void {
        const m = self.storeMutation(value, self.canOperate(), "retry");
        return self.store.operatorRetry(m, self.ids.next());
    }
    pub fn terminate(self: Client, value: Mutation) Error!void {
        const m = self.storeMutation(value, self.principal.role == .admin, "terminate");
        return self.store.operatorTerminate(m, self.ids.next());
    }
    pub fn migrate(self: Client, value: Migration) Error!void {
        const authorized = self.principal.role == .admin and self.inScope(value.mutation.tenant, value.mutation.namespace);
        return self.store.migrateDefinition(.{ .workflow_id = value.mutation.workflow_id, .tenant = value.mutation.tenant, .namespace = value.mutation.namespace, .target_version = value.target_version, .target_hash = value.target_hash, .principal = self.principal.name, .reason = value.mutation.reason, .idempotency_key = value.mutation.idempotency_key, .authorized = authorized, .request_hash = migrationRequestHash(value), .event_id = self.ids.next(), .task_id = self.ids.next(), .steps = value.steps });
    }
    fn canOperate(self: Client) bool {
        return self.principal.role != .viewer;
    }
    fn inScope(self: Client, tenant: []const u8, namespace: []const u8) bool {
        return std.mem.eql(u8, tenant, self.principal.tenant) and std.mem.eql(u8, namespace, self.principal.namespace);
    }
    fn storeMutation(self: Client, value: Mutation, role_allowed: bool, action: []const u8) sqlite.OperatorMutation {
        return .{ .workflow_id = value.workflow_id, .tenant = value.tenant, .namespace = value.namespace, .principal = self.principal.name, .reason = value.reason, .idempotency_key = value.idempotency_key, .authorized = role_allowed and self.inScope(value.tenant, value.namespace), .request_hash = requestHash(value, action) };
    }
};

fn requestHash(value: Mutation, action: []const u8) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    const bytes = value.workflow_id.toBytes();
    hasher.update(&bytes);
    hasher.update(value.tenant);
    hasher.update(value.namespace);
    hasher.update(value.reason);
    hasher.update(action);
    return hasher.final();
}

fn migrationRequestHash(value: Migration) u64 {
    var hasher = std.hash.Fnv1a_64.init();
    var base: [8]u8 = undefined;
    std.mem.writeInt(u64, &base, requestHash(value.mutation, "migrate"), .big);
    hasher.update(&base);
    var target: [12]u8 = undefined;
    std.mem.writeInt(u32, target[0..4], value.target_version, .big);
    std.mem.writeInt(u64, target[4..12], value.target_hash, .big);
    hasher.update(&target);
    for (value.steps, 0..) |step, index| {
        var bytes: [24]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], @intCast(index), .big);
        std.mem.writeInt(u32, bytes[8..12], step.from_version, .big);
        std.mem.writeInt(u32, bytes[12..16], step.to_version, .big);
        std.mem.writeInt(u64, bytes[16..24], step.identity_hash, .big);
        hasher.update(&bytes);
    }
    return hasher.final();
}
