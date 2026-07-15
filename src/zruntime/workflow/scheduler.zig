const sqlite = @import("sqlite.zig");
/// Namespace-scoped scheduler. SQLite atomically fences every claim with the runtime epoch.
pub const Scheduler = struct {
    store: *sqlite.Store,
    tenant: []const u8,
    namespace: []const u8,
    pub fn poll(self: Scheduler) sqlite.Error!?sqlite.Claim {
        return self.store.claimWorkflowTask(self.tenant, self.namespace);
    }
};
