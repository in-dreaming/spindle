const std = @import("std");
pub const StepFn = *const fn (allocator: std.mem.Allocator, state: []const u8) anyerror![]u8;
pub const Step = struct { from_version: u32, to_version: u32, apply: StepFn };

/// Applies explicit, contiguous state migrations. No definition version is selected implicitly.
pub fn migrate(allocator: std.mem.Allocator, steps: []const Step, from: u32, to: u32, state: []const u8) anyerror![]u8 {
    if (from > to) return error.VersionRegression;
    var current = try allocator.dupe(u8, state);
    errdefer allocator.free(current);
    var version = from;
    while (version < to) : (version += 1) {
        var found: ?Step = null;
        for (steps) |step| if (step.from_version == version and step.to_version == version + 1) {
            found = step;
            break;
        };
        const step = found orelse return error.MigrationGap;
        const next = try step.apply(allocator, current);
        allocator.free(current);
        current = next;
    }
    return current;
}
