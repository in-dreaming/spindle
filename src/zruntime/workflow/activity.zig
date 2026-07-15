const core = @import("../core/root.zig");
const executor = @import("../executor/root.zig");
const event = @import("event.zig");
const std = @import("std");

/// At-least-once idempotency key. Repeated delivery must reuse the original completed result.
pub const ActivityKey = struct { workflow_id: core.StableId, command_sequence: u64 };
pub const Timeout = struct { schedule_to_start_ms: ?u64 = null, start_to_close_ms: ?u64 = null, heartbeat_ms: ?u64 = null };
pub const FailureKind = enum { application, timeout, cancelled, non_retryable };
pub const Failure = struct { kind: FailureKind, code: u32, message: []const u8 };
pub const Input = struct { key: ActivityKey, payload: event.Payload, timeout: Timeout };
pub const Result = union(enum) { completed: event.Payload, failed: Failure };
pub const RetryPolicy = struct { initial_backoff_ms: u64, max_backoff_ms: u64, max_attempts: u32, jitter_percent: u8 = 0, non_retryable: []const u32 = &.{} };

/// Selects the only executor class on which an activity handler may execute.
pub const ExecutorKind = enum { compute, blocking };
/// Declares that a handler can safely repeat an external effect for the same ActivityKey.
pub const Idempotency = enum { required, test_only };
/// Immutable trace context carried with an activity delivery.
pub const Trace = struct { trace_id: core.StableId = .{ .high = 0, .low = 0 } };
pub const Heartbeat = struct {
    context: ?*anyopaque = null,
    beat_fn: ?*const fn (?*anyopaque) anyerror!void = null,
    pub fn beat(self: Heartbeat) !void {
        if (self.beat_fn) |f| try f(self.context);
    }
};
/// Context supplied to an activity handler. It deliberately has no workflow-state reference.
pub const Context = struct {
    key: ActivityKey,
    attempt: u32,
    deadline_utc_ms: ?i64,
    cancellation: executor.CancellationToken,
    trace: Trace,
    heartbeat: Heartbeat,
};
pub const Handler = *const fn (Context, event.Payload) anyerror!Result;
pub const Registration = struct {
    stable_name: []const u8,
    type_id: u64,
    input_schema: core.schema.SchemaKey,
    output_schema: core.schema.SchemaKey,
    ownership: []const u8,
    idempotency: Idempotency,
    executor: ExecutorKind,
    timeouts: Timeout = .{},
    retry_policy: RetryPolicy = .{ .initial_backoff_ms = 0, .max_backoff_ms = 0, .max_attempts = 1 },
    handler: Handler,
};

/// Frozen process-local registry of stable activity definitions.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Registration) = .empty,
    frozen: bool = false,
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *Registry, value: Registration) !void {
        if (self.frozen) return error.RegistryFrozen;
        if (value.idempotency != .required) return error.IdempotencyContractRequired;
        for (self.entries.items) |existing| if (existing.type_id == value.type_id or std.mem.eql(u8, existing.stable_name, value.stable_name)) return error.DuplicateActivity;
        try self.entries.append(self.allocator, value);
    }
    pub fn registerForTest(self: *Registry, value: Registration) !void {
        if (self.frozen) return error.RegistryFrozen;
        for (self.entries.items) |existing| if (existing.type_id == value.type_id or std.mem.eql(u8, existing.stable_name, value.stable_name)) return error.DuplicateActivity;
        try self.entries.append(self.allocator, value);
    }
    pub fn freeze(self: *Registry) void {
        self.frozen = true;
    }
    pub fn findByName(self: *const Registry, name: []const u8) ?Registration {
        for (self.entries.items) |entry| if (std.mem.eql(u8, entry.stable_name, name)) return entry;
        return null;
    }
};
