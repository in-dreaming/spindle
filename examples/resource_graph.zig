const std = @import("std");
const spindle = @import("spindle");

pub fn main() void {
    var graph = spindle.resource_graph.ResourceTaskGraph.init(std.heap.page_allocator);
    defer graph.deinit();
}
