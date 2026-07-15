const core = @import("../core/root.zig");
const event = @import("event.zig");

/// At-least-once idempotency key. Repeated delivery must reuse the original completed result.
pub const ActivityKey = struct { workflow_id: core.StableId, command_sequence: u64 };
pub const Timeout = struct { schedule_to_close_ms: ?u64 = null, start_to_close_ms: ?u64 = null, heartbeat_ms: ?u64 = null };
pub const FailureKind = enum { application, timeout, cancelled, non_retryable };
pub const Failure = struct { kind: FailureKind, code: u32, message: []const u8 };
pub const Input = struct { key: ActivityKey, payload: event.Payload, timeout: Timeout };
pub const Result = union(enum) { completed: event.Payload, failed: Failure };
