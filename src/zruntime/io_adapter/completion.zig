const std = @import("std");
const executor = @import("../executor/root.zig");
const Event = @import("../sync/event.zig").Event;

/// Creates a one-shot completion. The producer owns `finish`; consumers may
/// wait or attach a caller-owned continuation task which is scheduled exactly once.
pub fn Completion(comptime T: type) type {
    return struct {
        const Self = @This();
        result: ?T = null,
        failed: bool = false,
        trace_id: u64 = 0,
        done: Event = Event.init(.manual, false),
        completed: std.atomic.Value(bool) = .init(false),
        continuation: ?*executor.Task = null,
        continuation_executor: ?executor.Executor = null,
        lock: std.Io.Mutex = .init,
        pub fn init(trace_id: u64) Self {
            return .{ .trace_id = trace_id };
        }
        pub fn finish(self: *Self, value: T) !void {
            try self.complete(value, false);
        }
        pub fn fail(self: *Self) !void {
            try self.complete(null, true);
        }
        fn complete(self: *Self, value: ?T, failed: bool) !void {
            try self.lock.lock(std.Options.debug_io);
            if (self.completed.load(.acquire)) {
                self.lock.unlock(std.Options.debug_io);
                return error.AlreadyCompleted;
            }
            self.result = value;
            self.failed = failed;
            self.completed.store(true, .release);
            const task = self.continuation;
            const target = self.continuation_executor;
            self.lock.unlock(std.Options.debug_io);
            self.done.set();
            if (task) |continuation| if (target) |selected| try selected.submit(continuation, .{});
        }
        pub fn then(self: *Self, target: executor.Executor, task: *executor.Task) !void {
            try self.lock.lock(std.Options.debug_io);
            defer self.lock.unlock(std.Options.debug_io);
            if (self.continuation != null) return error.ContinuationAlreadySet;
            self.continuation = task;
            self.continuation_executor = target;
            if (self.completed.load(.acquire)) try target.submit(task, .{});
        }
        pub fn wait(self: *Self) !T {
            try self.done.wait(null, .{});
            if (self.failed) return error.Failed;
            return self.result.?;
        }
    };
}
