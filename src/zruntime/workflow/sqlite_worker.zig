const std = @import("std");
const command = @import("command.zig");
const definition = @import("definition.zig");
const sqlite = @import("sqlite.zig");
const worker = @import("worker.zig");

pub const Error = sqlite.Error || worker.Error || std.mem.Allocator.Error || anyerror;

/// Single-process worker. Database reads and commits bracket deterministic transition execution.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    store: *sqlite.Store,
    registry: *const definition.Registry,
    tenant: []const u8,
    namespace: []const u8,
    command_capacity: usize = 64,

    /// Claims and processes at most one task. Returns false when no task is ready.
    pub fn runOne(self: Worker) Error!bool {
        const claim = (try self.store.claimWorkflowTask(self.tenant, self.namespace)) orelse return false;
        if (self.registry.find(claim.definition_id, claim.definition_version)) |def| {
            var loaded = try self.store.loadWorkflowTask(self.allocator, claim);
            defer loaded.deinit();
            const commands = try self.allocator.alloc(command.Command, self.command_capacity);
            defer self.allocator.free(commands);
            const transition = worker.processDecisions(def, claim.workflow_id, loaded.state, loaded.last_processed_sequence, loaded.events, commands) catch |err| {
                try self.store.blockWorkflowTask(claim);
                return err;
            };
            const utc_ms = self.store.clock.utcNow();
            var scheduled = try worker.normalizeCommands(self.allocator, claim.workflow_id, transition.last_decision_sequence, utc_ms, transition.commands);
            defer worker.deinitScheduledWork(self.allocator, &scheduled);
            try self.store.commitWorkflowTaskTransition(.{
                .claim = claim,
                .tenant = loaded.tenant,
                .namespace = loaded.namespace,
                .state = transition.state,
                .status = transition.status,
                .last_processed_sequence = transition.last_decision_sequence,
                .optional_snapshot = transition.optional_snapshot,
                .scheduled = scheduled,
                .updated_utc_ms = utc_ms,
            });
            return true;
        } else |_| {
            try self.store.blockWorkflowTask(claim);
            return error.DefinitionUnavailable;
        }
    }
};
