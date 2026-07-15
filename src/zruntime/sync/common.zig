const std = @import("std");
pub const Deadline = @import("../platform/park.zig").Deadline;
pub const WaitError = error{ Timeout, Cancelled };
/// Minimal cancellation view. `cancelled` is acquire-loaded by waits; cancellation stores release.
pub const CancelWait = struct {
    pub const Registration = struct {
        word: *align(@alignOf(u32)) const u32,
        next: ?*Registration = null,
        notify_fn: ?*const fn (*Registration) void = null,
        pub fn notify(self: *Registration) void {
            if (self.notify_fn) |notify_fn| return notify_fn(self);
            @import("../platform/park.zig").wakeAll(self.word);
        }
    };
    cancelled: ?*const std.atomic.Value(bool) = null,
    context: ?*anyopaque = null,
    register_fn: ?*const fn (?*anyopaque, *Registration) void = null,
    unregister_fn: ?*const fn (?*anyopaque, *Registration) void = null,
    pub fn isCancelled(self: CancelWait) bool {
        return if (self.cancelled) |value| value.load(.acquire) else false;
    }
    pub fn register(self: CancelWait, registration: *Registration) void {
        if (self.register_fn) |register_fn| register_fn(self.context, registration);
    }
    pub fn unregister(self: CancelWait, registration: *Registration) void {
        if (self.unregister_fn) |unregister_fn| unregister_fn(self.context, registration);
    }
};
