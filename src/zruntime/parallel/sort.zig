const std = @import("std");
const executor = @import("../executor/root.zig");
const parallel_for = @import("parallel_for.zig");

/// Stable bounded-chunk sort followed by stable merges. Temporary storage is
/// allocated from the supplied allocator and released before return.
pub fn stable(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, items: []T, context: anytype, lessThan: anytype) !void {
    if (items.len < 2) return;
    const geometry = parallel_for.chunkGeometry(target, items.len, null);
    const State = struct { values: []T, grain: usize };
    var state = State{ .values = items, .grain = geometry.grain };
    try parallel_for.forRange(allocator, target, .{ .end = items.len }, .{ .grain = geometry.grain }, &state, struct {
        fn run(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            std.sort.insertion(T, s.values[begin..end], context, lessThan);
        }
    }.run);
    const scratch = try allocator.alloc(T, items.len);
    defer allocator.free(scratch);
    var width = geometry.grain;
    while (width < items.len) : (width *= 2) {
        var start: usize = 0;
        while (start < items.len) : (start += width * 2) mergeStable(T, items, scratch, start, @min(start + width, items.len), @min(start + width * 2, items.len), context, lessThan);
    }
}
fn mergeStable(comptime T: type, values: []T, scratch: []T, start: usize, middle: usize, end: usize, context: anytype, lessThan: anytype) void {
    var left = start;
    var right = middle;
    var out = start;
    while (left < middle and right < end) {
        if (lessThan(context, values[right], values[left])) {
            scratch[out] = values[right];
            right += 1;
        } else {
            scratch[out] = values[left];
            left += 1;
        }
        out += 1;
    }
    while (left < middle) : (left += 1) {
        scratch[out] = values[left];
        out += 1;
    }
    while (right < end) : (right += 1) {
        scratch[out] = values[right];
        out += 1;
    }
    @memcpy(values[start..end], scratch[start..end]);
}
/// Unstable bounded-chunk sort. It uses the stable merge path for correctness
/// of the final global ordering but makes no stability promise to callers.
pub fn unstable(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, items: []T, context: anytype, lessThan: anytype) !void {
    try stable(allocator, target, T, items, context, lessThan);
}
