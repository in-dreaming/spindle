const std = @import("std");
const stats = @import("stats.zig");

/// A bounded single-producer/single-consumer queue. Exactly one thread may call each side.
pub fn SpscQueue(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        items: []T,
        capacity: usize,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),
        closed: std.atomic.Value(bool) = .init(false),
        counters: stats.Counters = .{},
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            return .{ .allocator = allocator, .items = try allocator.alloc(T, capacity), .capacity = capacity };
        }
        /// Calls dispose for every queued value before releasing storage.
        pub fn deinit(self: *Self, comptime dispose: fn (T) void) void {
            while (true) {
                const value = self.tryPop() catch break;
                dispose(value);
            }
            self.allocator.free(self.items);
        }
        /// Closes producers. Values published before close remain available to the consumer.
        pub fn close(self: *Self) void {
            self.closed.store(true, .release);
        }
        pub fn tryPush(self: *Self, value: T) error{ Full, Closed }!void {
            if (self.closed.load(.acquire)) return error.Closed;
            const tail = self.tail.load(.monotonic);
            if (tail -% self.head.load(.acquire) >= self.capacity) {
                _ = self.counters.full.fetchAdd(1, .monotonic);
                return error.Full;
            }
            self.items[tail % self.capacity] = value;
            self.tail.store(tail +% 1, .release);
            _ = self.counters.push.fetchAdd(1, .monotonic);
        }
        pub fn tryPop(self: *Self) error{ Empty, Closed }!T {
            const head = self.head.load(.monotonic);
            if (head == self.tail.load(.acquire)) {
                _ = self.counters.empty.fetchAdd(1, .monotonic);
                return if (self.closed.load(.acquire)) error.Closed else error.Empty;
            }
            const value = self.items[head % self.capacity];
            self.head.store(head +% 1, .release);
            _ = self.counters.pop.fetchAdd(1, .monotonic);
            return value;
        }
        pub fn pushSlice(self: *Self, values: []const T) usize {
            var n: usize = 0;
            for (values) |value| {
                self.tryPush(value) catch break;
                n += 1;
            }
            return n;
        }
        pub fn popSlice(self: *Self, values: []T) usize {
            var n: usize = 0;
            for (values) |*value| {
                value.* = self.tryPop() catch break;
                n += 1;
            }
            return n;
        }
        pub fn snapshot(self: *const Self) stats.Stats {
            return self.counters.snapshot();
        }
    };
}
