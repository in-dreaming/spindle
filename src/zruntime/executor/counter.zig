const std = @import("std");
const Event = @import("../sync/event.zig").Event;

/// Completion counter. Add work before exposing it to another thread; waiting is thread-safe.
pub const Counter = struct {
    value: std.atomic.Value(usize) = .init(0),
    done: Event = Event.init(.manual, true),
    pub fn add(self: *Counter, count: usize) void {
        if (count == 0) return;
        const prior = self.value.fetchAdd(count, .acq_rel);
        if (prior == 0) self.done.reset();
    }
    pub fn complete(self: *Counter) void {
        const prior = self.value.fetchSub(1, .acq_rel);
        std.debug.assert(prior > 0);
        if (prior == 1) self.done.set();
    }
    pub fn wait(self: *Counter) !void {
        try self.done.wait(null, .{});
    }
    pub fn isComplete(self: *const Counter) bool {
        return self.value.load(.acquire) == 0;
    }
};
