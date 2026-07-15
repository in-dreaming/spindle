const std = @import("std");
const Event = @import("event.zig").Event;
const ResetMode = @import("event.zig").ResetMode;
const common = @import("common.zig");
pub const Latch = struct {
    count: std.atomic.Value(u32),
    done: Event,
    pub fn init(count: u32) Latch {
        return .{ .count = .init(count), .done = Event.init(.manual, count == 0) };
    }
    pub fn countDown(self: *Latch) !void {
        var old = self.count.load(.acquire);
        while (old != 0) {
            if (self.count.cmpxchgWeak(old, old - 1, .acq_rel, .acquire)) |current| {
                old = current;
                continue;
            }
            if (old == 1) self.done.set();
            return;
        }
        return error.Underflow;
    }
    pub fn wait(self: *Latch, deadline: ?common.Deadline, cancel: common.CancelWait) common.WaitError!void {
        return self.done.wait(deadline, cancel);
    }
};
