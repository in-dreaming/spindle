const std = @import("std");
const postgres = @import("workflow_postgres");

test "postgres migrations run against a real server" {
    const dsn = std.posix.getenv("SPINDLE_TEST_PG_DSN") orelse return error.MissingPostgresDsn;
    var connection = try postgres.Connection.init(dsn);
    defer connection.deinit();
    try connection.migrate();
    try connection.migrate();
}

test "postgres migrations serialize across real connections" {
    const dsn = std.posix.getenv("SPINDLE_TEST_PG_DSN") orelse return error.MissingPostgresDsn;
    var first = try postgres.Connection.init(dsn);
    defer first.deinit();
    var second = try postgres.Connection.init(dsn);
    defer second.deinit();
    try first.migrate();
    try second.migrate();
}

test "bounded postgres pool exhausts and recovers a lease" {
    const dsn = std.posix.getenv("SPINDLE_TEST_PG_DSN") orelse return error.MissingPostgresDsn;
    var pool = try postgres.Pool.init(std.testing.allocator, dsn, 1);
    defer pool.deinit();
    var lease = try pool.tryAcquire();
    try std.testing.expectError(error.PoolExhausted, pool.tryAcquire());
    lease.release();
    var recovered = try pool.tryAcquire();
    recovered.release();
}
