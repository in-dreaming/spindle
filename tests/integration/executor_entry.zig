const std = @import("std");
const spindle_executor = @import("spindle_executor");

test "executor-only entry excludes upper-level and orchestration modules" {
    try std.testing.expect(@hasDecl(spindle_executor, "executor"));
    try std.testing.expect(!@hasDecl(spindle_executor, "runtime"));
    try std.testing.expect(!@hasDecl(spindle_executor, "parallel"));
    try std.testing.expect(!@hasDecl(spindle_executor, "task_graph"));
    try std.testing.expect(!@hasDecl(spindle_executor, "ecs"));
    try std.testing.expect(!@hasDecl(spindle_executor, "resource_graph"));
    try std.testing.expect(!@hasDecl(spindle_executor, "workflow"));
}

test "executor-only entry runs an intrusive task" {
    var value: usize = 0;
    var task = spindle_executor.executor.Task.init(struct {
        fn run(current: *spindle_executor.executor.Task) void {
            const output: *usize = @ptrCast(@alignCast(current.context.?));
            output.* += 1;
        }
    }.run, &value);
    var inline_executor = spindle_executor.executor.InlineExecutor{};
    try inline_executor.submit(&task, .{});
    try std.testing.expectEqual(@as(usize, 1), value);
}
