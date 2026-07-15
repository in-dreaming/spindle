const core = @import("../core/root.zig");

pub const WorkflowId = core.StableId;
pub const Status = enum { running, completed, failed, cancelled };

/// Persisted instance metadata. State bytes are managed by the persistence layer added later.
pub const Instance = struct {
    id: WorkflowId,
    definition_id: u64,
    definition_version: u32,
    status: Status = .running,
    sequence: u64 = 0,
    state_version: u64 = 0,
    owner_epoch: u64 = 0,
    created_utc_ms: i64,
    updated_utc_ms: i64,

    pub fn applySequence(self: *Instance, sequence: u64, utc_ms: i64) error{ InvalidSequence, TerminalInstance }!void {
        if (self.status != .running) return error.TerminalInstance;
        if (sequence != self.sequence + 1) return error.InvalidSequence;
        self.sequence = sequence;
        self.state_version += 1;
        self.updated_utc_ms = utc_ms;
    }
    pub fn finish(self: *Instance, status: Status, utc_ms: i64) error{ InvalidTerminalStatus, TerminalInstance }!void {
        if (self.status != .running) return error.TerminalInstance;
        if (status == .running) return error.InvalidTerminalStatus;
        self.status = status;
        self.updated_utc_ms = utc_ms;
    }
};
