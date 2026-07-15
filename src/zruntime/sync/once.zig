const std = @import("std");
const park = @import("../platform/park.zig");
pub const Once = struct {
    state: std.atomic.Value(u32) = .init(0), // 0 new, 1 running, 2 complete
    /// Runs `function` once. A failure resets state, allowing one later caller to retry.
    pub fn call(self: *Once, comptime function: anytype, args: anytype) !void {
        while (true) {
            const state = self.state.load(.acquire);
            if (state == 2) return;
            if (state == 0 and self.state.cmpxchgStrong(0, 1, .acquire, .acquire) == null) {
                @call(.auto, function, args) catch |err| {
                    self.state.store(0, .release);
                    park.wakeAll(&self.state.raw);
                    return err;
                };
                self.state.store(2, .release);
                park.wakeAll(&self.state.raw);
                return;
            }
            park.wait(&self.state.raw, 1, null) catch {};
        }
    }
};
