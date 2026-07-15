const std = @import("std");
const spindle = @import("spindle");

test "workflow feature is absent" {
    try std.testing.expect(!@hasDecl(spindle.workflow, "Definition"));
}
