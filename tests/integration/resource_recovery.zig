const std = @import("std");
const spindle = @import("spindle");

test "separate-process commit fault states reopen safely" {
    const io = std.Options.debug_io;
    const before = spindle.resource_graph.CommitStore.init(io, "spindle-task13-child-before-record");
    try before.recover();
    try std.testing.expectError(error.FileNotFound, before.current());

    const after_record = spindle.resource_graph.CommitStore.init(io, "spindle-task13-child-after-record");
    try after_record.recover();
    try std.testing.expectEqual(@as(u64, 1), try after_record.current());

    const after_pointer = spindle.resource_graph.CommitStore.init(io, "spindle-task13-child-after-pointer");
    try after_pointer.recover();
    try std.testing.expectEqual(@as(u64, 1), try after_pointer.current());

    inline for ([_][]const u8{ "spindle-task13-child-before-record", "spindle-task13-child-after-record", "spindle-task13-child-after-pointer" }) |directory| {
        std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    }
}
