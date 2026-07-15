/// Immutable SQLite migration bytes. Checksums are recorded before commit.
pub const workflow_sqlite_v1 = @embedFile("0001_workflow_sqlite.sql");
