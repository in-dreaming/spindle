const std = @import("std");
const sqlite = @import("sqlite.zig");
/// Scans the indexed durable timer queue. SQLite UTC time is the only authority.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    store: *sqlite.Store,
    tenant: []const u8,
    namespace: []const u8,
    pub fn runOne(self: Worker) !bool {
        const claim = (try self.store.claimTimer(self.allocator, self.tenant, self.namespace)) orelse return false;
        try self.store.fireTimer(claim, self.tenant, self.namespace, claim.schema);
        return true;
    }
};
