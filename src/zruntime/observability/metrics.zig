const std = @import("std");

/// Immutable label declaration. Labels are supplied at registration, never allocated on the hot path.
pub const Label = struct { key: []const u8, value: []const u8 };

/// Lock-free unsigned counter. Relaxed increments only publish numeric accumulation.
pub const Counter = struct {
    value: std.atomic.Value(u64) = .init(0),
    labels: []const Label = &.{},

    pub fn add(self: *Counter, amount: u64) void {
        _ = self.value.fetchAdd(amount, .monotonic);
    }
    pub fn load(self: *const Counter) u64 {
        return self.value.load(.acquire);
    }
};

/// Lock-free signed gauge.
pub const Gauge = struct {
    value: std.atomic.Value(i64) = .init(0),
    labels: []const Label = &.{},

    pub fn set(self: *Gauge, amount: i64) void {
        self.value.store(amount, .release);
    }
    pub fn load(self: *const Gauge) i64 {
        return self.value.load(.acquire);
    }
};

/// Fixed-boundary histogram. Boundaries and labels must outlive the histogram.
pub const Histogram = struct {
    boundaries: []const u64,
    buckets: []std.atomic.Value(u64),
    labels: []const Label = &.{},

    pub fn init(allocator: std.mem.Allocator, boundaries: []const u64, labels: []const Label) !Histogram {
        const buckets = try allocator.alloc(std.atomic.Value(u64), boundaries.len + 1);
        for (buckets) |*bucket| bucket.* = .init(0);
        return .{ .boundaries = boundaries, .buckets = buckets, .labels = labels };
    }

    pub fn deinit(self: *Histogram, allocator: std.mem.Allocator) void {
        allocator.free(self.buckets);
        self.* = undefined;
    }

    /// Records an observation without allocation. Relaxed increment is sufficient for a snapshot count.
    pub fn observe(self: *Histogram, value: u64) void {
        var index: usize = 0;
        while (index < self.boundaries.len and value > self.boundaries[index]) : (index += 1) {}
        _ = self.buckets[index].fetchAdd(1, .monotonic);
    }

    /// Copies bucket counts into caller-provided storage, avoiding a snapshot allocation.
    pub fn snapshot(self: *const Histogram, output: []u64) error{BufferTooSmall}!void {
        if (output.len < self.buckets.len) return error.BufferTooSmall;
        for (self.buckets, 0..) |*bucket, index| output[index] = bucket.load(.acquire);
    }
};

test "metrics accumulate exactly" {
    var counter: Counter = .{};
    counter.add(3);
    counter.add(4);
    try std.testing.expectEqual(@as(u64, 7), counter.load());
}
