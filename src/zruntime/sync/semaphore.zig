const std = @import("std");
const park = @import("../platform/park.zig");
const common = @import("common.zig");
pub const Semaphore = struct {
    permits: std.atomic.Value(u32),
    max: u32,
    pub fn init(initial: u32, max: u32) !Semaphore {
        if (initial > max) return error.InvalidInitialCount;
        return .{ .permits = .init(initial), .max = max };
    }
    pub fn release(self: *Semaphore, count: u32) !void {
        var old = self.permits.load(.acquire);
        while (true) {
            if (count > self.max - old) return error.Overflow;
            if (self.permits.cmpxchgWeak(old, old + count, .release, .acquire)) |next| {
                old = next;
                continue;
            } else break;
        }
        if (count > 1) park.wakeAll(&self.permits.raw) else park.wakeOne(&self.permits.raw);
    }
    pub fn acquire(self: *Semaphore, deadline: ?common.Deadline, cancel: common.CancelWait) common.WaitError!void {
        var registration: common.CancelWait.Registration = .{ .word = &self.permits.raw };
        cancel.register(&registration);
        defer cancel.unregister(&registration);
        while (true) {
            if (cancel.isCancelled()) return error.Cancelled;
            var old = self.permits.load(.acquire);
            while (old > 0) {
                if (self.permits.cmpxchgWeak(old, old - 1, .acq_rel, .acquire)) |next| {
                    old = next;
                } else return;
            }
            park.wait(&self.permits.raw, 0, deadline) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
            };
        }
    }
};
