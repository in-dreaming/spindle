const std = @import("std");
const spindle = @import("spindle");

test "runtime owns lower-layer resources and shuts down without leaks" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    var runtime = try spindle.runtime.Runtime.init(std.testing.allocator, .{ .io = threaded.io(), .compute_workers = 1, .blocking_workers = 1, .queue_capacity = 4, .observability_capacity = 2 });
    defer runtime.deinit();
    runtime.eventSink().emit(.{ .monotonic_ns = runtime.clock().monotonicNow(), .kind = "runtime.started" });
    const report = runtime.shutdown(null);
    try std.testing.expect(report.completed);
    try std.testing.expectEqual(@as(usize, 0), report.outstanding_detached);
}

test "runtime initialization failures unwind acquired resources" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    inline for ([_]spindle.runtime.Fault{ .clock, .compute, .blocking, .pump, .observability }) |fault| {
        try std.testing.expectError(error.InjectedFailure, spindle.runtime.Runtime.init(std.testing.allocator, .{ .io = threaded.io(), .fault = fault }));
    }
}

test "expired runtime shutdown deadline retains owned resources for deinit" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    var runtime = try spindle.runtime.Runtime.init(std.testing.allocator, .{ .io = threaded.io() });
    defer runtime.deinit();
    try std.testing.expect(!(runtime.shutdown(0)).completed);
}
