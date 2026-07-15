const spindle = @import("spindle");

pub fn main() void {
    _ = spindle;
    @import("std").debug.print("{{\"benchmark\":\"bootstrap\",\"samples\":1,\"throughput\":0,\"latency_ns\":0}}\n", .{});
}
