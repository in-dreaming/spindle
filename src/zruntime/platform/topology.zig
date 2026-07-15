const std = @import("std");
pub fn logicalCpuCount() !usize {
    return std.Thread.getCpuCount();
}
