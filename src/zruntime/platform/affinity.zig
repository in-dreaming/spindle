const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ Unsupported, InvalidCpu, PermissionDenied, Unexpected };
/// Binds the current Linux thread to the supplied logical CPUs. Other targets report capability absence.
pub fn setCurrent(cpus: []const usize) Error!void {
    if (builtin.os.tag != .linux) return error.Unsupported;
    const linux = std.os.linux;
    if (cpus.len == 0) return error.InvalidCpu;
    var set: linux.cpu_set_t = [_]usize{0} ** (linux.CPU_SETSIZE / @sizeOf(usize));
    for (cpus) |cpu| {
        if (cpu >= linux.CPU_SETSIZE * 8) return error.InvalidCpu;
        set[cpu / @bitSizeOf(usize)] |= @as(usize, 1) << @intCast(cpu % @bitSizeOf(usize));
    }
    linux.sched_setaffinity(0, &set) catch |err| switch (err) {
        error.PermissionDenied => return error.PermissionDenied,
        else => return error.Unexpected,
    };
}
