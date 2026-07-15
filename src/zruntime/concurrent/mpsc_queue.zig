const std = @import("std");
const MpmcQueue = @import("mpmc_queue.zig").MpmcQueue;
/// A bounded multi-producer/single-consumer queue. The consumer must be one registered thread; producers are unrestricted.
pub fn MpscQueue(comptime T: type) type {
    return struct {
        inner: MpmcQueue(T),
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !@This() {
            return .{ .inner = try .init(allocator, capacity) };
        }
        pub fn deinit(self: *@This(), comptime dispose: fn (T) void) void {
            self.inner.deinit(dispose);
        }
        pub fn close(self: *@This()) void {
            self.inner.close();
        }
        pub fn tryPush(self: *@This(), value: T) error{ Full, Closed }!void {
            return self.inner.tryPush(value);
        }
        pub fn tryPop(self: *@This()) error{ Empty, Closed }!T {
            return self.inner.tryPop();
        }
        pub fn snapshot(self: *const @This()) @import("stats.zig").Stats {
            return self.inner.snapshot();
        }
    };
}
