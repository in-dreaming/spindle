const std = @import("std");
pub const SpinMutex = struct {
    state: std.atomic.Value(bool) = .init(false),
    contention: std.atomic.Value(u64) = .init(0),
    /// Acquires with acquire semantics; unlock publishes the critical section with release semantics.
    pub fn lock(self: *SpinMutex) void {
        var spins: u32 = 1;
        while (self.state.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            _ = self.contention.fetchAdd(1, .monotonic);
            for (0..spins) |_| std.atomic.spinLoopHint();
            spins = @min(spins *| 2, 64);
        }
    }
    pub fn tryLock(self: *SpinMutex) bool {
        return self.state.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }
    pub fn unlock(self: *SpinMutex) void {
        self.state.store(false, .release);
    }
    pub fn contentionCount(self: *const SpinMutex) u64 {
        return self.contention.load(.monotonic);
    }
};
