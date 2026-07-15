/// SQLite-only diagnostics and bounded maintenance request types.
pub const Integrity = enum { healthy, repairable_queue_state, corrupt };

/// Counts gathered during the startup recovery transaction.
pub const Recovery = struct {
    workflow_tasks: u64 = 0,
    activities: u64 = 0,
    timers: u64 = 0,
    outbox: u64 = 0,
};

/// Payload-free health information. A corrupt report never changes persistent data.
pub const Report = struct {
    schema_version: u32 = 0,
    migration_hashes_valid: bool = false,
    previous_shutdown_clean: bool = false,
    history_gaps: u64 = 0,
    snapshot_checksum_failures: u64 = 0,
    orphan_records: u64 = 0,
    pending_work: u64 = 0,
    database_bytes: u64 = 0,
    wal_bytes: u64 = 0,
    last_checkpoint_utc_ms: i64 = 0,
    recovery: Recovery = .{},
    integrity: Integrity = .corrupt,
};

/// Bounded maintenance options. `cancelled` is checked before each operation.
pub const Maintenance = struct {
    incremental_vacuum_pages: u32 = 0,
    checkpoint: bool = true,
    cancelled: ?*const fn (?*anyopaque) bool = null,
    cancellation_context: ?*anyopaque = null,
};

/// Actual work completed by one bounded maintenance call.
pub const MaintenanceProgress = struct {
    checkpointed: bool = false,
    wal_frames: u32 = 0,
    checkpointed_frames: u32 = 0,
    vacuumed_pages: u32 = 0,
    cancelled: bool = false,
};
