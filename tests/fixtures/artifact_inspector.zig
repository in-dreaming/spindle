const std = @import("std");

/// Checks raw static-library bytes. Arguments prefixed with `+` must occur and `-` must not occur.
pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) return error.InvalidArguments;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .unlimited);
    defer init.gpa.free(bytes);
    for (args[2..]) |rule| {
        if (rule.len < 2 or (rule[0] != '+' and rule[0] != '-')) return error.InvalidArguments;
        const found = std.mem.indexOf(u8, bytes, rule[1..]) != null;
        if (rule[0] == '+' and !found) return error.RequiredMarkerMissing;
        if (rule[0] == '-' and found) return error.DisabledMarkerPresent;
    }
}
