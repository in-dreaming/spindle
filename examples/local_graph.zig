const std = @import("std");
const spindle = @import("spindle");

pub fn main() void {
    var graph = spindle.task_graph.LocalTaskGraph.init(std.heap.page_allocator);
    defer graph.deinit();
}
