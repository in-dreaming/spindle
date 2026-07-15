const std = @import("std");
const spindle = @import("spindle");

test "aggregate roots match the active feature profile" {
    try std.testing.expectEqual(spindle.runtime.Features.task_graph, !spindle.task_graph.unavailable);
    try std.testing.expectEqual(spindle.runtime.Features.ecs, !spindle.ecs.unavailable);
    try std.testing.expectEqual(spindle.runtime.Features.resource_graph, !spindle.resource_graph.unavailable);
    try std.testing.expectEqual(spindle.runtime.Features.workflow, !spindle.workflow.unavailable);
}

test "inspector and replay bundle disclose only enabled modules" {
    const modules = spindle.runtime.InspectorProtocol.enabledModules();
    var saw_sqlite = false;
    for (modules) |name| {
        if (std.mem.eql(u8, name, "workflow_sqlite")) saw_sqlite = true;
    }
    try std.testing.expectEqual(spindle.runtime.Features.workflow_sqlite, saw_sqlite);
    const replay = spindle.runtime.ReplayBundle{};
    try std.testing.expectEqualSlices([]const u8, modules, replay.modules);
}
