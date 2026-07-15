const std = @import("std");

pub const Deadline = std.Io.Clock.Timestamp;
pub const WaitError = error{Timeout};

/// Returns a monotonic deadline suitable for every sync wait in this package.
pub fn deadlineAfter(ns: u64) Deadline {
    const io = std.Options.debug_io;
    return std.Io.Clock.Timestamp.now(io, .awake).addDuration(.{ .raw = .{ .nanoseconds = ns }, .clock = .awake });
}

pub fn expired(deadline: ?Deadline) bool {
    const d = deadline orelse return false;
    const now = Deadline.now(std.Options.debug_io, d.clock);
    return now.raw.nanoseconds >= d.raw.nanoseconds;
}

/// Blocks in the standard library's OS-backed futex implementation. Callers must recheck state:
/// wakeups are deliberately indistinguishable from spurious wakeups at this layer.
pub fn wait(word: *align(@alignOf(u32)) const u32, expected: u32, deadline: ?Deadline) WaitError!void {
    if (expired(deadline)) return error.Timeout;
    const timeout: std.Io.Timeout = if (deadline) |d| .{ .deadline = d } else .none;
    std.Options.debug_io.futexWaitTimeout(u32, word, expected, timeout) catch {
        if (expired(deadline)) return error.Timeout;
        return;
    };
    if (expired(deadline)) return error.Timeout;
}

pub fn wakeOne(word: *align(@alignOf(u32)) const u32) void {
    std.Options.debug_io.futexWake(u32, word, 1);
}
pub fn wakeAll(word: *align(@alignOf(u32)) const u32) void {
    std.Options.debug_io.futexWake(u32, word, std.math.maxInt(u32));
}
