const std = @import("std");
const spindle = @import("spindle");

test "module aggregators are independently importable" {
    try std.testing.expect(@TypeOf(spindle.core) == type);
    try std.testing.expect(@TypeOf(spindle.platform) == type);
    try std.testing.expect(@TypeOf(spindle.sync) == type);
    try std.testing.expect(@TypeOf(spindle.concurrent) == type);
    try std.testing.expect(@TypeOf(spindle.executor) == type);
    try std.testing.expect(@TypeOf(spindle.parallel) == type);
    try std.testing.expect(@TypeOf(spindle.task_graph) == type);
    try std.testing.expect(@TypeOf(spindle.ecs) == type);
    try std.testing.expect(@TypeOf(spindle.resource_graph) == type);
    try std.testing.expect(@TypeOf(spindle.runtime) == type);
    try std.testing.expect(@TypeOf(spindle.workflow) == type);
    try std.testing.expect(@TypeOf(spindle.io_adapter) == type);
    try std.testing.expect(@TypeOf(spindle.observability) == type);
    try std.testing.expect(@TypeOf(spindle.testing) == type);
}
