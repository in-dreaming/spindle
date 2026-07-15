const std = @import("std");
const platform = @import("../platform/root.zig");
const sync = @import("../sync/root.zig");
const sqlite_worker = @import("sqlite_worker.zig");

/// Owns and joins the single-process workflow polling thread.
pub const WorkflowRuntime = struct {
    worker: sqlite_worker.Worker,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    done: sync.Event = sync.Event.init(.manual, false),
    thread: ?std.Thread = null,

    pub fn init(worker: sqlite_worker.Worker) WorkflowRuntime {
        return .{ .worker = worker };
    }
    pub fn deinit(self: *WorkflowRuntime) void {
        self.shutdown(null) catch {};
        self.* = undefined;
    }
    pub fn start(self: *WorkflowRuntime) !void {
        if (self.thread != null) return error.AlreadyStarted;
        self.stopping.store(false, .release);
        self.failed.store(false, .release);
        self.done.reset();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    /// Requests cooperative shutdown and joins by the monotonic deadline.
    pub fn shutdown(self: *WorkflowRuntime, deadline: ?platform.park.Deadline) !void {
        self.stopping.store(true, .release);
        if (self.thread == null) return;
        self.done.wait(deadline, .{}) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        self.thread.?.join();
        self.thread = null;
        if (self.failed.load(.acquire)) return error.WorkerFailed;
    }
    fn run(self: *WorkflowRuntime) void {
        defer self.done.set();
        while (!self.stopping.load(.acquire)) {
            const worked = self.worker.runOne() catch |err| switch (err) {
                error.DefinitionUnavailable => continue,
                else => {
                    self.failed.store(true, .release);
                    return;
                },
            };
            if (!worked) std.Thread.yield() catch {};
        }
    }
};
