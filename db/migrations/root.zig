/// Immutable SQLite migration bytes. Checksums are recorded before commit.
pub const workflow_sqlite_v1 = @embedFile("0001_workflow_sqlite.sql");
/// Additive task-18 queue fencing and delivery metadata.
pub const workflow_sqlite_v2 = @embedFile("0002_activity_timer_messaging.sql");
/// Child workflow relations and durable compensation plans.
pub const workflow_sqlite_v3 = @embedFile("0003_child_compensation.sql");
/// Operator audit, migration fencing, and archive discovery metadata.
pub const workflow_sqlite_v4 = @embedFile("0004_workflow_operator_archive.sql");
