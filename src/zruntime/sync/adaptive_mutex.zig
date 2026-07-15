const std = @import("std");
const park = @import("../platform/park.zig");
pub const AdaptiveMutex = struct {
    state: std.atomic.Value(u32) = .init(0), // 0 unlocked, 1 locked, 2 locked with waiters
    pub fn tryLock(self: *AdaptiveMutex) bool {
        return self.state.cmpxchgStrong(0, 1, .acquire, .monotonic) == null;
    }
    pub fn lock(self: *AdaptiveMutex) void {
        var spins: u32 = 0;
        while (!self.tryLock()) {
            if (spins < 32) {
                std.atomic.spinLoopHint();
                spins += 1;
                continue;
            }
            std.Thread.yield() catch {};
            // Exchange marks contention. If unlock won the race, this exchange acquires it.
            if (self.state.swap(2, .acquire) == 0) return;
            park.wait(&self.state.raw, 2, null) catch {};
        }
    }
    pub fn unlock(self: *AdaptiveMutex) void {
        const previous = self.state.swap(0, .release);
        if (previous == 2) park.wakeOne(&self.state.raw);
    }
};
