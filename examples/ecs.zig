const std = @import("std");
const spindle = @import("spindle");

pub fn main() !void {
    var world = try spindle.ecs.World.init(std.heap.page_allocator, .{});
    defer world.deinit();
    _ = try world.create();
}
