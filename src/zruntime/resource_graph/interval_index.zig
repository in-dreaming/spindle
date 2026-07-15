const std = @import("std");
pub const Interval = struct { start: u64, end: u64, value: u32 };
/// Sorted interval index. End is exclusive; adjacent equal-value intervals coalesce.
pub const Index = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(Interval) = .empty,
    pub fn init(allocator: std.mem.Allocator) Index {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Index) void {
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn overlaps(self: *const Index, start: u64, end: u64, out: *std.ArrayListUnmanaged(Interval), allocator: std.mem.Allocator) !void {
        if (start >= end) return error.InvalidInterval;
        for (self.items.items) |item| if (item.start < end and start < item.end) try out.append(allocator, item);
    }
    pub fn insert(self: *Index, start: u64, end: u64, value: u32) !void {
        if (start >= end) return error.InvalidInterval;
        var next: std.ArrayListUnmanaged(Interval) = .empty;
        defer next.deinit(self.allocator);
        for (self.items.items) |item| {
            if (item.end <= start or item.start >= end) try next.append(self.allocator, item) else {
                if (item.start < start) try next.append(self.allocator, .{ .start = item.start, .end = start, .value = item.value });
                if (item.end > end) try next.append(self.allocator, .{ .start = end, .end = item.end, .value = item.value });
            }
        }
        try next.append(self.allocator, .{ .start = start, .end = end, .value = value });
        std.mem.sort(Interval, next.items, {}, struct {
            fn less(_: void, a: Interval, b: Interval) bool {
                return a.start < b.start;
            }
        }.less);
        self.items.deinit(self.allocator);
        self.items = next;
        next = .empty;
        self.coalesce();
    }
    fn coalesce(self: *Index) void {
        var write: usize = 0;
        for (self.items.items) |item| {
            if (write > 0 and self.items.items[write - 1].end == item.start and self.items.items[write - 1].value == item.value) {
                self.items.items[write - 1].end = item.end;
            } else {
                self.items.items[write] = item;
                write += 1;
            }
        }
        self.items.items.len = write;
    }
};
test "interval index splits, coalesces, and reports overlaps" {
    var index = Index.init(std.testing.allocator);
    defer index.deinit();
    try index.insert(0, 10, 1);
    try index.insert(3, 7, 2);
    try std.testing.expectEqual(@as(usize, 3), index.items.items.len);
    try index.insert(3, 7, 1);
    try std.testing.expectEqual(@as(usize, 1), index.items.items.len);
    var hits: std.ArrayListUnmanaged(Interval) = .empty;
    defer hits.deinit(std.testing.allocator);
    try index.overlaps(4, 8, &hits, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
}
