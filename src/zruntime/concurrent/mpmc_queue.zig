const std = @import("std");
const stats = @import("stats.zig");

/// A bounded lock-free MPMC queue using per-slot sequence numbers. Any number of threads may push and pop.
pub fn MpmcQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        const Slot = struct { sequence: std.atomic.Value(usize), value: T = undefined };
        allocator: std.mem.Allocator,
        slots: []Slot,
        mask: usize,
        enqueue: std.atomic.Value(usize) = .init(0),
        dequeue: std.atomic.Value(usize) = .init(0),
        closed: std.atomic.Value(bool) = .init(false),
        counters: stats.Counters = .{},
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity < 2 or !std.math.isPowerOfTwo(capacity)) return error.InvalidCapacity;
            const slots = try allocator.alloc(Slot, capacity);
            for (slots, 0..) |*slot, i| slot.* = .{ .sequence = .init(i) };
            return .{ .allocator = allocator, .slots = slots, .mask = capacity - 1 };
        }
        pub fn deinit(self: *Self, comptime dispose: fn (T) void) void {
            while (true) {
                const value = self.tryPop() catch break;
                dispose(value);
            }
            self.allocator.free(self.slots);
        }
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }
        pub fn tryPush(self: *Self, value: T) error{ Full, Closed }!void {
            if (self.closed.load(.acquire)) return error.Closed;
            var pos = self.enqueue.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const seq = slot.sequence.load(.acquire);
                const dif: isize = @as(isize, @bitCast(seq -% pos));
                if (dif == 0) {
                    if (self.enqueue.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        _ = self.counters.contention.fetchAdd(1, .monotonic);
                        pos = actual;
                    } else {
                        slot.value = value;
                        slot.sequence.store(pos +% 1, .release);
                        _ = self.counters.push.fetchAdd(1, .monotonic);
                        return;
                    }
                } else if (dif < 0) {
                    _ = self.counters.full.fetchAdd(1, .monotonic);
                    return error.Full;
                } else {
                    _ = self.counters.contention.fetchAdd(1, .monotonic);
                    pos = self.enqueue.load(.monotonic);
                }
            }
        }
        pub fn tryPop(self: *Self) error{ Empty, Closed }!T {
            var pos = self.dequeue.load(.monotonic);
            while (true) {
                const slot = &self.slots[pos & self.mask];
                const seq = slot.sequence.load(.acquire);
                const dif: isize = @as(isize, @bitCast(seq -% (pos +% 1)));
                if (dif == 0) {
                    if (self.dequeue.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                        _ = self.counters.contention.fetchAdd(1, .monotonic);
                        pos = actual;
                    } else {
                        const value = slot.value;
                        slot.sequence.store(pos +% self.mask +% 1, .release);
                        _ = self.counters.pop.fetchAdd(1, .monotonic);
                        return value;
                    }
                } else if (dif < 0) {
                    _ = self.counters.empty.fetchAdd(1, .monotonic);
                    return if (self.closed.load(.acquire)) error.Closed else error.Empty;
                } else {
                    _ = self.counters.contention.fetchAdd(1, .monotonic);
                    pos = self.dequeue.load(.monotonic);
                }
            }
        }
        pub fn snapshot(self: *const Self) stats.Stats {
            return self.counters.snapshot();
        }
    };
}
