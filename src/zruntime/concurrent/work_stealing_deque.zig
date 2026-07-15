const std = @import("std");
const stats = @import("stats.zig");

/// A fixed-capacity Chase-Lev deque. One owner calls bottom operations; any threads may steal from the top.
pub fn WorkStealingDeque(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        items: []T,
        mask: usize,
        top: std.atomic.Value(usize) = .init(0),
        bottom: std.atomic.Value(usize) = .init(0),
        owner: std.atomic.Value(std.Thread.Id) = .init(0),
        closed: std.atomic.Value(bool) = .init(false),
        counters: stats.Counters = .{},
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity < 2 or !std.math.isPowerOfTwo(capacity)) return error.InvalidCapacity;
            return .{ .allocator = allocator, .items = try allocator.alloc(T, capacity), .mask = capacity - 1 };
        }
        pub fn deinit(self: *Self, comptime dispose: fn (T) void) void {
            while (true) {
                const value = self.popBottom() catch break;
                dispose(value);
            }
            self.allocator.free(self.items);
        }
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }
        /// Owner-only. The release store makes the item visible to stealers.
        pub fn pushBottom(self: *Self, value: T) error{ Full, Closed, NotOwner }!void {
            try self.ensureOwner();
            if (self.closed.load(.acquire)) return error.Closed;
            const bottom = self.bottom.load(.monotonic);
            if (bottom -% self.top.load(.acquire) > self.mask) {
                _ = self.counters.full.fetchAdd(1, .monotonic);
                return error.Full;
            }
            self.items[bottom & self.mask] = value;
            self.bottom.store(bottom +% 1, .release);
            _ = self.counters.push.fetchAdd(1, .monotonic);
        }
        /// Owner-only. The final item is claimed with a CAS against competing stealers.
        pub fn popBottom(self: *Self) error{ Empty, Closed, NotOwner }!T {
            try self.ensureOwner();
            var bottom = self.bottom.load(.monotonic);
            if (bottom == 0) return self.emptyResult();
            bottom -%= 1;
            self.bottom.store(bottom, .monotonic);
            const top = self.top.load(.acquire);
            if (top > bottom) {
                self.bottom.store(top, .monotonic);
                return self.emptyResult();
            }
            const value = self.items[bottom & self.mask];
            if (top == bottom) {
                if (self.top.cmpxchgStrong(top, top +% 1, .seq_cst, .monotonic) != null) {
                    self.bottom.store(top +% 1, .monotonic);
                    return self.emptyResult();
                }
                self.bottom.store(top +% 1, .monotonic);
            }
            _ = self.counters.pop.fetchAdd(1, .monotonic);
            return value;
        }
        /// May be called by any non-owner thread. Acquire observes the owner's published slot.
        pub fn stealTop(self: *Self) error{ Empty, Closed }!T {
            const top = self.top.load(.acquire);
            const bottom = self.bottom.load(.acquire);
            if (top >= bottom) return self.emptyResult();
            const value = self.items[top & self.mask];
            if (self.top.cmpxchgStrong(top, top +% 1, .seq_cst, .monotonic) != null) {
                _ = self.counters.contention.fetchAdd(1, .monotonic);
                return self.emptyResult();
            }
            _ = self.counters.pop.fetchAdd(1, .monotonic);
            return value;
        }
        fn emptyResult(self: *Self) error{ Empty, Closed } {
            _ = self.counters.empty.fetchAdd(1, .monotonic);
            return if (self.closed.load(.acquire)) error.Closed else error.Empty;
        }
        /// Registers the calling thread as the sole bottom-operation owner. A different caller receives NotOwner.
        fn ensureOwner(self: *Self) error{NotOwner}!void {
            const current = std.Thread.getCurrentId();
            const owner = self.owner.load(.acquire);
            if (owner == current) return;
            if (owner == 0 and self.owner.cmpxchgStrong(0, current, .acq_rel, .acquire) == null) return;
            return error.NotOwner;
        }
        pub fn snapshot(self: *const Self) stats.Stats {
            return self.counters.snapshot();
        }
    };
}
