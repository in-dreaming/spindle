const std = @import("std");
/// Runtime EWMA estimate. It is advisory only; declared resource budgets remain authoritative.
pub const Estimate = struct {
    mean_ns: u64 = 0,
    samples: u64 = 0,
    pub fn observe(self: *Estimate, elapsed_ns: u64) void {
        self.mean_ns = if (self.samples == 0) elapsed_ns else (self.mean_ns * 7 + elapsed_ns) / 8;
        self.samples += 1;
    }
};
pub const Score = struct { node: u32, downstream_unlock: u32, estimate: Estimate };
/// Orders ready work by downstream unlock first, then historical runtime. This does not reserve resources.
pub fn less(_: void, left: Score, right: Score) bool {
    if (left.downstream_unlock != right.downstream_unlock) return left.downstream_unlock > right.downstream_unlock;
    return left.estimate.mean_ns > right.estimate.mean_ns;
}
test "ewma affects only later scores" {
    var estimate: Estimate = .{};
    estimate.observe(80);
    estimate.observe(160);
    try std.testing.expectEqual(@as(u64, 90), estimate.mean_ns);
}
