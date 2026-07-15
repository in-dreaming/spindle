const std = @import("std");

/// A non-synchronizing snapshot of container operation counters.
pub const Stats = struct { push: u64, pop: u64, full: u64, empty: u64, contention: u64 };

pub const Counters = struct {
    push: std.atomic.Value(u64) = .init(0),
    pop: std.atomic.Value(u64) = .init(0),
    full: std.atomic.Value(u64) = .init(0),
    empty: std.atomic.Value(u64) = .init(0),
    contention: std.atomic.Value(u64) = .init(0),
    pub fn snapshot(self: *const Counters) Stats {
        return .{ .push = self.push.load(.monotonic), .pop = self.pop.load(.monotonic), .full = self.full.load(.monotonic), .empty = self.empty.load(.monotonic), .contention = self.contention.load(.monotonic) };
    }
};
