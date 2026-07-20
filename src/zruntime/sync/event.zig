const std = @import("std");
const park = @import("../platform/park.zig");
const common = @import("common.zig");
pub const ResetMode = enum { manual, auto };
pub const Event = struct {
    mode: ResetMode,
    state: std.atomic.Value(u32) = .init(0), // bit 0 signalled; remaining bits are a generation
    wait_sequence: std.atomic.Value(u32) = .init(0),
    pub fn init(mode: ResetMode, initially_set: bool) Event {
        return .{ .mode = mode, .state = .init(if (initially_set) 1 else 0) };
    }
    pub fn set(self: *Event) void {
        _ = self.state.fetchOr(1, .release);
        _ = self.wait_sequence.fetchAdd(1, .release);
        if (self.mode == .manual) park.wakeAll(&self.wait_sequence.raw) else park.wakeOne(&self.wait_sequence.raw);
    }
    pub fn reset(self: *Event) void {
        _ = self.state.fetchAnd(~@as(u32, 1), .release);
    }
    pub fn wait(self: *Event, deadline: ?common.Deadline, cancel: common.CancelWait) common.WaitError!void {
        var registration: common.CancelWait.Registration = .{ .word = &self.wait_sequence.raw, .notify_fn = notifyCancellation };
        cancel.register(&registration);
        defer cancel.unregister(&registration);
        while (true) {
            if (cancel.isCancelled()) return error.Cancelled;
            // Snapshot the futex generation before the signal state. If set
            // races this observation, either the state load sees the signal
            // or futexWait observes a changed generation and does not park.
            const sequence = self.wait_sequence.load(.acquire);
            const value = self.state.load(.acquire);
            if (value & 1 != 0) {
                if (self.mode == .auto and self.state.cmpxchgWeak(value, value & ~@as(u32, 1), .acq_rel, .acquire) != null) continue;
                return;
            }
            if (cancel.isCancelled()) return error.Cancelled;
            park.wait(&self.wait_sequence.raw, sequence, deadline) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
            };
        }
    }
    fn notifyCancellation(registration: *common.CancelWait.Registration) void {
        const sequence: *std.atomic.Value(u32) = @ptrCast(@alignCast(@constCast(registration.word)));
        _ = sequence.fetchAdd(1, .release);
        park.wakeAll(registration.word);
    }
};
