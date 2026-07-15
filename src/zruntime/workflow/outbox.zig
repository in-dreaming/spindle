const core = @import("../core/root.zig");
const sqlite = @import("sqlite.zig");
const event = @import("event.zig");
/// External transport facade. A successful publish may be repeated before the durable completion mark.
pub const Transport = struct {
    context: ?*anyopaque,
    publish_fn: *const fn (?*anyopaque, core.StableId, []const u8) anyerror!void,
    pub fn publish(self: Transport, id: core.StableId, payload: []const u8) !void {
        try self.publish_fn(self.context, id, payload);
    }
};
pub const Publisher = struct {
    allocator: @import("std").mem.Allocator,
    store: *sqlite.Store,
    tenant: []const u8,
    namespace: []const u8,
    transport: Transport,
    pub fn runOne(self: Publisher) !bool {
        const claim = (try self.store.claimOutbox(self.allocator, self.tenant, self.namespace)) orelse return false;
        self.transport.publish(claim.message_id, claim.payload) catch {
            try self.store.abandonOutbox(claim);
            return error.TransportFailure;
        };
        try self.store.finishOutbox(claim);
        return true;
    }
};

/// In-process test/default transport which accepts into another real SQLite inbox.
pub const Loopback = struct {
    store: *sqlite.Store,
    tenant: []const u8,
    namespace: []const u8,
    workflow_id: core.StableId,
    schema: core.schema.SchemaKey,
    pub fn transport(self: *Loopback) Transport {
        return .{ .context = self, .publish_fn = publish };
    }
    fn publish(context: ?*anyopaque, message_id: core.StableId, payload: []const u8) !void {
        const self: *Loopback = @ptrCast(@alignCast(context.?));
        try self.store.appendInbox(.{ .task_id = derive(message_id, 1), .event_id = derive(message_id, 2), .message_id = message_id, .workflow_id = self.workflow_id, .tenant = self.tenant, .namespace = self.namespace, .kind = event.Kind.signal_received, .schema = self.schema, .payload = payload, .utc_ms = self.store.clock.utcNow() });
    }
};

fn derive(id: core.StableId, discriminator: u64) core.StableId {
    return .{ .high = id.high ^ discriminator, .low = id.low };
}
