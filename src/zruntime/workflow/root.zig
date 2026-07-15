/// Durable workflow protocol and deterministic replay. It performs no I/O or background work.
pub const definition = @import("definition.zig");
pub const instance = @import("instance.zig");
pub const event = @import("event.zig");
pub const command = @import("command.zig");
pub const activity = @import("activity.zig");
pub const retry = @import("retry.zig");
pub const snapshot = @import("snapshot.zig");
pub const migration = @import("migration.zig");
pub const replay = @import("replay.zig");
/// Database-neutral transactional persistence contract.
pub const persistence = @import("persistence.zig");
pub const worker = @import("worker.zig");
pub const worker_runtime = @import("worker_runtime.zig");
const build_options = @import("build_options");
/// SQLite persistence is absent unless the SQLite workflow feature is enabled.
pub const sqlite = if (build_options.workflow_sqlite) @import("sqlite.zig") else @import("sqlite_disabled.zig");
pub const client = if (build_options.workflow_sqlite) @import("client.zig") else @import("client_disabled.zig");
pub const scheduler = if (build_options.workflow_sqlite) @import("scheduler.zig") else @import("scheduler_disabled.zig");
pub const sqlite_worker = if (build_options.workflow_sqlite) @import("sqlite_worker.zig") else @import("sqlite_worker_disabled.zig");
pub const sqlite_runtime = if (build_options.workflow_sqlite) @import("sqlite_runtime.zig") else @import("sqlite_runtime_disabled.zig");
pub const WorkflowId = instance.WorkflowId;
pub const Definition = definition.Definition;
pub const Registry = definition.Registry;
