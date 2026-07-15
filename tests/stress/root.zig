const std = @import("std");
const build_options = @import("build_options");
const spindle = @import("spindle");

test "stress harness has a bounded reproducible iteration count" {
    _ = spindle;
    try std.testing.expect(build_options.iterations > 0);
}
