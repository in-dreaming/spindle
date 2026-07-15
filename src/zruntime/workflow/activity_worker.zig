const std = @import("std");
const activity = @import("activity.zig");
const event = @import("event.zig");
const executor = @import("../executor/root.zig");
const retry = @import("retry.zig");
const sqlite = @import("sqlite.zig");

/// Delivers SQLite-backed activities at least once. Handlers execute after their claim transaction commits.
pub const Worker = struct {
    allocator: std.mem.Allocator,
    store: *sqlite.Store,
    registry: *const activity.Registry,
    tenant: []const u8,
    namespace: []const u8,
    compute: executor.Executor,
    blocking: executor.Executor,
    shutdown: ?executor.CancellationToken = null,
    pub fn runOne(self: Worker) !bool {
        var claim = (try self.store.claimActivity(self.allocator, self.tenant, self.namespace)) orelse return false;
        const registration = self.registry.findByName(claim.payload) orelse {
            try self.store.finishActivity(claim, self.tenant, self.namespace, event.Kind.activity_failed, .{ .id = 0, .version = 1 }, "unregistered activity");
            return true;
        };
        if (registration.input_schema.id != claim.schema.id or registration.input_schema.version != claim.schema.version) {
            try self.store.finishActivity(claim, self.tenant, self.namespace, event.Kind.activity_failed, .{ .id = 0, .version = 1 }, "activity input schema mismatch");
            return true;
        }
        const now = self.store.clock.utcNow();
        if (registration.timeouts.schedule_to_start_ms) |limit| {
            if (elapsed(claim.scheduled_utc_ms, now) >= limit) {
                try self.resolveFailure(claim, registration, .{ .kind = .timeout, .code = 1001, .message = "schedule-to-start timeout" });
                return true;
            }
        }
        var cancel = executor.CancellationSource{};
        const Job = struct {
            registration: activity.Registration,
            claim: *sqlite.ActivityClaim,
            cancel: *executor.CancellationSource,
            store: *sqlite.Store,
            last_heartbeat_utc_ms: std.atomic.Value(i64),
            result: ?activity.Result = null,
            fn beat(context: ?*anyopaque) !void {
                const job: *@This() = @ptrCast(@alignCast(context.?));
                try job.store.heartbeatActivity(job.claim.*);
                job.last_heartbeat_utc_ms.store(job.store.clock.utcNow(), .release);
            }
            fn run(task: *executor.Task) void {
                const job: *@This() = @ptrCast(@alignCast(task.context.?));
                const deadline = if (job.registration.timeouts.start_to_close_ms) |ms| job.claim.started_utc_ms + @as(i64, @intCast(ms)) else null;
                job.result = job.registration.handler(.{ .key = .{ .workflow_id = job.claim.workflow_id, .command_sequence = job.claim.command_sequence }, .attempt = job.claim.attempt, .deadline_utc_ms = deadline, .cancellation = job.cancel.token(), .trace = .{}, .heartbeat = .{ .context = job, .beat_fn = beat } }, .{ .schema = job.claim.schema, .bytes = job.claim.payload }) catch |err| .{ .failed = .{ .kind = .application, .code = 1, .message = @errorName(err) } };
            }
        };
        var job = Job{ .registration = registration, .claim = &claim, .cancel = &cancel, .store = self.store, .last_heartbeat_utc_ms = .init(claim.started_utc_ms) };
        var task = executor.Task.init(Job.run, &job);
        const target = if (registration.executor == .blocking) self.blocking else self.compute;
        target.submit(&task, .{}) catch {
            try self.resolveFailure(claim, registration, .{ .kind = .application, .code = 1007, .message = "activity executor unavailable" });
            return true;
        };
        var forced_failure: ?activity.Failure = null;
        while (switch (task.status()) {
            .completed, .failed, .cancelled => false,
            else => true,
        }) {
            const current = self.store.clock.utcNow();
            if (self.shutdown != null and self.shutdown.?.isCancelled()) {
                forced_failure = .{ .kind = .cancelled, .code = 1006, .message = "activity worker shutdown" };
            } else if (try self.store.activityCancelled(claim, self.tenant, self.namespace)) {
                forced_failure = .{ .kind = .cancelled, .code = 1004, .message = "activity cancelled" };
            } else if (registration.timeouts.start_to_close_ms) |limit| {
                if (elapsed(claim.started_utc_ms, current) >= limit) forced_failure = .{ .kind = .timeout, .code = 1002, .message = "start-to-close timeout" };
            }
            if (forced_failure == null) if (registration.timeouts.heartbeat_ms) |limit| {
                if (elapsed(job.last_heartbeat_utc_ms.load(.acquire), current) >= limit) forced_failure = .{ .kind = .timeout, .code = 1003, .message = "heartbeat timeout" };
            };
            if (forced_failure != null) cancel.cancel();
            std.Thread.yield() catch {};
        }
        try task.wait();
        try task.waitQueueReleased();
        const result: activity.Result = if (forced_failure) |failure| .{ .failed = failure } else job.result orelse .{ .failed = .{ .kind = .application, .code = 2, .message = "activity did not return" } };
        switch (result) {
            .completed => |payload| {
                if (payload.schema.id != registration.output_schema.id or payload.schema.version != registration.output_schema.version) {
                    try self.resolveFailure(claim, registration, .{ .kind = .non_retryable, .code = 1005, .message = "activity output schema mismatch" });
                } else try self.store.finishActivity(claim, self.tenant, self.namespace, event.Kind.activity_completed, payload.schema, payload.bytes);
            },
            .failed => |failure| try self.resolveFailure(claim, registration, failure),
        }
        return true;
    }
    fn resolveFailure(self: Worker, claim: sqlite.ActivityClaim, registration: activity.Registration, failure: activity.Failure) !void {
        if (retry.shouldRetry(registration.retry_policy, claim.attempt, failure)) {
            const seed = claim.workflow_id.low ^ claim.command_sequence ^ claim.attempt;
            try self.store.retryActivity(claim, self.tenant, self.namespace, retry.delayMs(registration.retry_policy, claim.attempt, seed));
        } else try self.store.finishActivity(claim, self.tenant, self.namespace, event.Kind.activity_failed, .{ .id = 0, .version = 1 }, failure.message);
    }
};

fn elapsed(start: i64, now: i64) u64 {
    if (now <= start) return 0;
    return @intCast(now - start);
}
