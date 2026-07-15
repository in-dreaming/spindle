const std = @import("std");
const park = @import("../platform/park.zig");
const common = @import("common.zig");
pub const Barrier = struct {
    participants: u32,
    arrived: std.atomic.Value(u32) = .init(0),
    generation: std.atomic.Value(u32) = .init(0),
    pub fn init(participants: u32) !Barrier {
        if (participants == 0) return error.InvalidParticipantCount;
        return .{ .participants = participants };
    }
    pub fn arriveAndWait(self: *Barrier, deadline: ?common.Deadline, cancel: common.CancelWait) (common.WaitError || error{TooManyArrivals})!void {
        var registration: common.CancelWait.Registration = .{ .word = &self.generation.raw };
        cancel.register(&registration);
        defer cancel.unregister(&registration);
        const generation = self.generation.load(.acquire);
        const old = self.arrived.fetchAdd(1, .acq_rel);
        if (old + 1 > self.participants) {
            _ = self.arrived.fetchSub(1, .acq_rel);
            return error.TooManyArrivals;
        }
        if (old + 1 == self.participants) {
            self.arrived.store(0, .release);
            _ = self.generation.fetchAdd(1, .release);
            park.wakeAll(&self.generation.raw);
            return;
        }
        while (self.generation.load(.acquire) == generation) {
            if (cancel.isCancelled()) return error.Cancelled;
            park.wait(&self.generation.raw, generation, deadline) catch |err| switch (err) {
                error.Timeout => return error.Timeout,
            };
        }
    }
};
