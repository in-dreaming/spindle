const std = @import("std");
const executor = @import("../executor/root.zig");

/// Cooperative polling loop invoked on the dedicated workflow executor. Implementations must observe
/// `stopping` between claimed tasks and return after a cancellation request.
pub const PollLoop = *const fn (?*anyopaque, *const std.atomic.Value(bool)) void;

/// Owns the explicitly detached workflow poll loop. It never creates a thread itself; the supplied
/// executor determines the dedicated worker thread and shutdown joins the detached handle.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    executor: executor.Executor,
    poll_context: ?*anyopaque,
    poll_loop: PollLoop,
    stopping: std.atomic.Value(bool) = .init(false),
    tracker: executor.DetachedTracker,
    handle: ?executor.DetachedHandle = null,

    pub fn init(allocator: std.mem.Allocator, target: executor.Executor, poll_context: ?*anyopaque, poll_loop: PollLoop) Runtime {
        return .{ .allocator = allocator, .executor = target, .poll_context = poll_context, .poll_loop = poll_loop, .tracker = executor.DetachedTracker.init(allocator) };
    }

    pub fn deinit(self: *Runtime) void {
        self.shutdown();
        self.tracker.deinit();
        self.* = undefined;
    }

    /// Starts exactly one detached poll loop. The runtime remains the owner until shutdown/deinit.
    pub fn start(self: *Runtime) !void {
        if (self.handle != null) return error.AlreadyStarted;
        self.stopping.store(false, .release);
        self.handle = try executor.submitTrackedDetached(&self.tracker, self.allocator, self.executor, run, self);
    }

    /// Requests cooperative polling shutdown and joins the detached loop. The loop owns any in-flight
    /// database operation and must leave its lease recoverable if it cannot commit before returning.
    pub fn shutdown(self: *Runtime) void {
        self.stopping.store(true, .release);
        if (self.handle) |*handle| {
            handle.wait() catch {};
            handle.deinit();
            self.handle = null;
        }
    }

    fn run(task: *executor.Task) void {
        const self: *Runtime = @ptrCast(@alignCast(task.context orelse {
            task.fail();
            return;
        }));
        self.poll_loop(self.poll_context, &self.stopping);
    }
};

test "runtime owns and joins its detached loop" {
    var pump = try executor.PumpExecutor.init(std.testing.allocator, 1);
    defer pump.deinit();
    var calls: usize = 0;
    const Probe = struct {
        fn poll(context: ?*anyopaque, stopping: *const std.atomic.Value(bool)) void {
            const value: *usize = @ptrCast(@alignCast(context.?));
            if (!stopping.load(.acquire)) value.* += 1;
        }
    };
    var runtime = Runtime.init(std.testing.allocator, pump.executor(), &calls, Probe.poll);
    defer runtime.deinit();
    try runtime.start();
    _ = pump.drain(1);
    runtime.shutdown();
    try std.testing.expectEqual(@as(usize, 1), calls);
}
