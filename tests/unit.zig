const std = @import("std");
const spindle = @import("spindle");

test "public package imports without initialization" {
    try std.testing.expect(@TypeOf(spindle) == type);
}
