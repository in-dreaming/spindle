const std = @import("std");
const AdaptiveMutex = @import("adaptive_mutex.zig").AdaptiveMutex;
const common = @import("common.zig");
const park = @import("../platform/park.zig");

/// Condition notification paired with `AdaptiveMutex`. Predicates are always rechecked by callers.
pub const Condition = struct {
    generation: std.atomic.Value(u32) = .init(0),

    pub fn signal(self: *Condition) void {
        _ = self.generation.fetchAdd(1, .release);
        park.wakeOne(&self.generation.raw);
    }

    pub fn broadcast(self: *Condition) void {
        _ = self.generation.fetchAdd(1, .release);
        park.wakeAll(&self.generation.raw);
    }

    /// Releases `mutex` while blocked and reacquires it before returning.
    pub fn wait(self: *Condition, mutex: *AdaptiveMutex, deadline: ?common.Deadline, cancel: common.CancelWait) common.WaitError!void {
        const observed = self.generation.load(.acquire);
        var registration: common.CancelWait.Registration = .{ .word = &self.generation.raw };
        cancel.register(&registration);
        defer cancel.unregister(&registration);
        mutex.unlock();
        defer mutex.lock();
        while (self.generation.load(.acquire) == observed) {
            if (cancel.isCancelled()) return error.Cancelled;
            park.wait(&self.generation.raw, observed, deadline) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
            };
        }
    }
};
