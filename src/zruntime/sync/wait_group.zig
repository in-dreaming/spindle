const std = @import("std");
const Event = @import("event.zig").Event;
const common = @import("common.zig");
pub const WaitGroup = struct {
    count: std.atomic.Value(u32) = .init(0),
    done: Event = Event.init(.manual, true),
    pub fn add(self: *WaitGroup, count: u32) !void {
        var old = self.count.load(.acquire);
        while (true) {
            if (count > std.math.maxInt(u32) - old) return error.Overflow;
            if (self.count.cmpxchgWeak(old, old + count, .acq_rel, .acquire)) |current| {
                old = current;
                continue;
            }
            break;
        }
        if (old == 0 and count != 0) self.done.reset();
    }
    pub fn doneOne(self: *WaitGroup) !void {
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
    pub fn wait(self: *WaitGroup, deadline: ?common.Deadline, cancel: common.CancelWait) common.WaitError!void {
        while (self.count.load(.acquire) != 0) {
            try self.done.wait(deadline, cancel);
        }
    }
};
