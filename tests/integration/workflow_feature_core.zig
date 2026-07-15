const std = @import("std");
const spindle = @import("spindle");

test "workflow core excludes sqlite imports" {
    try std.testing.expect(@hasDecl(spindle.workflow, "Definition"));
    try std.testing.expect(!@hasDecl(spindle.workflow.sqlite, "Store"));
}
