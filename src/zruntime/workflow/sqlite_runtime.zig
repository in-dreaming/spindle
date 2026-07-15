const std = @import("std");
const platform = @import("../platform/root.zig");
const sync = @import("../sync/root.zig");
const sqlite_worker = @import("sqlite_worker.zig");
const activity_worker = @import("activity_worker.zig");
const timer_worker = @import("timer_worker.zig");
const outbox = @import("outbox.zig");
const executor = @import("../executor/root.zig");

/// Owns and joins the single-process workflow polling thread.
pub const WorkflowRuntime = struct {
    worker: sqlite_worker.Worker,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    idle_word: std.atomic.Value(u32) = .init(0),
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
        _ = self.idle_word.fetchAdd(1, .release);
        platform.park.wakeAll(&self.idle_word.raw);
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
            if (!worked) {
                const observed = self.idle_word.load(.acquire);
                platform.park.wait(&self.idle_word.raw, observed, platform.park.deadlineAfter(10 * std.time.ns_per_ms)) catch {};
            }
        }
    }
};

/// Owns all single-process SQLite workflow loops. Every loop is joined during shutdown.
pub const WorkflowSubsystem = struct {
    workflow: sqlite_worker.Worker,
    activities: activity_worker.Worker,
    timers: timer_worker.Worker,
    publisher: outbox.Publisher,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    activity_cancel: executor.CancellationSource = .{},
    idle_word: std.atomic.Value(u32) = .init(0),
    done: [4]sync.Event = .{ sync.Event.init(.manual, false), sync.Event.init(.manual, false), sync.Event.init(.manual, false), sync.Event.init(.manual, false) },
    threads: [4]?std.Thread = .{ null, null, null, null },

    pub fn init(workflow: sqlite_worker.Worker, activities: activity_worker.Worker, timers: timer_worker.Worker, publisher: outbox.Publisher) WorkflowSubsystem {
        return .{ .workflow = workflow, .activities = activities, .timers = timers, .publisher = publisher };
    }
    pub fn deinit(self: *WorkflowSubsystem) void {
        self.shutdown(null) catch {};
        self.* = undefined;
    }
    /// Starts every worker; a thread-creation failure cancels and joins workers already started.
    pub fn start(self: *WorkflowSubsystem) !void {
        if (self.threads[0] != null) return error.AlreadyStarted;
        self.stopping.store(false, .release);
        self.failed.store(false, .release);
        self.activity_cancel = .{};
        self.activities.shutdown = self.activity_cancel.token();
        for (&self.done) |*value| value.reset();
        inline for (0..4) |index| self.threads[index] = std.Thread.spawn(.{}, run, .{ self, index }) catch |err| {
            self.stopping.store(true, .release);
            self.activity_cancel.cancel();
            _ = self.idle_word.fetchAdd(1, .release);
            platform.park.wakeAll(&self.idle_word.raw);
            self.joinStarted();
            return err;
        };
    }
    /// Requests cooperative cancellation, then waits for and joins all four loops by deadline.
    pub fn shutdown(self: *WorkflowSubsystem, deadline: ?platform.park.Deadline) !void {
        self.stopping.store(true, .release);
        self.activity_cancel.cancel();
        _ = self.idle_word.fetchAdd(1, .release);
        platform.park.wakeAll(&self.idle_word.raw);
        if (self.threads[0] == null) return;
        for (&self.done) |*value| value.wait(deadline, .{}) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        self.joinStarted();
        if (self.failed.load(.acquire)) return error.WorkerFailed;
    }
    fn joinStarted(self: *WorkflowSubsystem) void {
        for (&self.threads) |*thread| if (thread.*) |value| {
            value.join();
            thread.* = null;
        };
    }
    fn run(self: *WorkflowSubsystem, index: usize) void {
        defer self.done[index].set();
        while (!self.stopping.load(.acquire)) {
            const worked = switch (index) {
                0 => self.workflow.runOne(),
                1 => self.activities.runOne(),
                2 => self.timers.runOne(),
                3 => self.publisher.runOne(),
                else => false,
            } catch {
                self.failed.store(true, .release);
                return;
            };
            if (!worked) {
                const observed = self.idle_word.load(.acquire);
                platform.park.wait(&self.idle_word.raw, observed, platform.park.deadlineAfter(10 * std.time.ns_per_ms)) catch {};
            }
        }
    }
};
