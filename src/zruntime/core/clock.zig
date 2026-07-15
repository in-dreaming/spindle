const std = @import("std");

/// Time source with monotonic nanoseconds for durations and UTC milliseconds for persistence.
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        monotonicNow: *const fn (ptr: *anyopaque) u64,
        utcNow: *const fn (ptr: *anyopaque) i64,
    };

    pub fn monotonicNow(self: Clock) u64 {
        return self.vtable.monotonicNow(self.ptr);
    }

    pub fn utcNow(self: Clock) i64 {
        return self.vtable.utcNow(self.ptr);
    }
};

/// Production clock backed by the operating system. It is safe for concurrent reads.
pub const SystemClock = struct {
    timer: std.time.Timer,

    pub fn init() !SystemClock {
        return .{ .timer = try std.time.Timer.start() };
    }

    pub fn clock(self: *SystemClock) Clock {
        return .{ .ptr = self, .vtable = &.{ .monotonicNow = monotonicNow, .utcNow = utcNow } };
    }

    fn monotonicNow(ptr: *anyopaque) u64 {
        const self: *SystemClock = @ptrCast(@alignCast(ptr));
        return self.timer.read();
    }

    fn utcNow(_: *anyopaque) i64 {
        return std.time.milliTimestamp();
    }
};

/// Test clock whose values advance only through explicit calls. Reads and advances are synchronized.
pub const VirtualClock = struct {
    monotonic_ns: std.atomic.Value(u64),
    utc_ms: std.atomic.Value(i64),

    pub fn init(monotonic_ns: u64, utc_ms: i64) VirtualClock {
        return .{ .monotonic_ns = .init(monotonic_ns), .utc_ms = .init(utc_ms) };
    }

    pub fn clock(self: *VirtualClock) Clock {
        return .{ .ptr = self, .vtable = &.{ .monotonicNow = monotonicNow, .utcNow = utcNow } };
    }

    /// Advances both clocks atomically with respect to individual readers. Release publishes the new values.
    pub fn advance(self: *VirtualClock, ns: u64, ms: i64) void {
        _ = self.monotonic_ns.fetchAdd(ns, .release);
        _ = self.utc_ms.fetchAdd(ms, .release);
    }

    fn monotonicNow(ptr: *anyopaque) u64 {
        const self: *VirtualClock = @ptrCast(@alignCast(ptr));
        return self.monotonic_ns.load(.acquire);
    }

    fn utcNow(ptr: *anyopaque) i64 {
        const self: *VirtualClock = @ptrCast(@alignCast(ptr));
        return self.utc_ms.load(.acquire);
    }
};
