const std = @import("std");
const spindle = @import("spindle");

pub fn main() !void {
    var inline_executor = spindle.executor.InlineExecutor{};
    var total: usize = 0;
    try spindle.parallel.forRange(std.heap.page_allocator, inline_executor.executor(), .{ .end = 16 }, .{ .grain = 4 }, &total, struct {
        fn run(value: *usize, begin: usize, end: usize, _: spindle.executor.CancellationToken) !void {
            value.* += end - begin;
        }
    }.run);
    if (total != 16) return error.InvalidParallelResult;
}
