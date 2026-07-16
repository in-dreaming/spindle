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
    allocator: std.mem.Allocator,
    workflow: sqlite_worker.Worker,
    activities: activity_worker.Worker,
    timers: timer_worker.Worker,
    publisher: outbox.Publisher,
    counts: [4]usize,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    activity_cancel: executor.CancellationSource = .{},
    idle_word: std.atomic.Value(u32) = .init(0),
    done: []sync.Event = &.{},
    threads: []?std.Thread = &.{},

    pub fn init(workflow: sqlite_worker.Worker, activities: activity_worker.Worker, timers: timer_worker.Worker, publisher: outbox.Publisher) WorkflowSubsystem {
        return initConfigured(std.heap.page_allocator, workflow, activities, timers, publisher, .{ 1, 1, 1, 1 });
    }
    pub fn initConfigured(allocator: std.mem.Allocator, workflow: sqlite_worker.Worker, activities: activity_worker.Worker, timers: timer_worker.Worker, publisher: outbox.Publisher, counts: [4]usize) WorkflowSubsystem {
        return .{ .allocator = allocator, .workflow = workflow, .activities = activities, .timers = timers, .publisher = publisher, .counts = counts };
    }
    pub fn deinit(self: *WorkflowSubsystem) void {
        self.shutdown(null) catch {};
        self.allocator.free(self.threads);
        self.allocator.free(self.done);
        self.* = undefined;
    }
    /// Starts every worker; a thread-creation failure cancels and joins workers already started.
    pub fn start(self: *WorkflowSubsystem) !void {
        for (self.threads) |thread| if (thread != null) return error.AlreadyStarted;
        if (self.threads.len == 0) {
            const total = self.counts[0] + self.counts[1] + self.counts[2] + self.counts[3];
            self.threads = try self.allocator.alloc(?std.Thread, total);
            errdefer {
                self.allocator.free(self.threads);
                self.threads = &.{};
            }
            self.done = try self.allocator.alloc(sync.Event, total);
            @memset(self.threads, null);
            for (self.done) |*value| value.* = sync.Event.init(.manual, false);
        }
        self.stopping.store(false, .release);
        self.failed.store(false, .release);
        self.activity_cancel = .{};
        self.activities.shutdown = self.activity_cancel.token();
        for (self.done) |*value| value.reset();
        for (self.threads, 0..) |*thread, index| thread.* = std.Thread.spawn(.{}, run, .{ self, index }) catch |err| {
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
        self.requestStop();
        try self.wait(deadline);
    }
    pub fn requestStop(self: *WorkflowSubsystem) void {
        self.stopping.store(true, .release);
        self.activity_cancel.cancel();
        _ = self.idle_word.fetchAdd(1, .release);
        platform.park.wakeAll(&self.idle_word.raw);
    }
    pub fn wait(self: *WorkflowSubsystem, deadline: ?platform.park.Deadline) !void {
        if (self.outstanding() == 0) {
            if (self.failed.load(.acquire)) return error.WorkerFailed;
            return;
        }
        for (self.done) |*value| value.wait(deadline, .{}) catch |err| switch (err) {
            error.Timeout => return error.Timeout,
            else => return err,
        };
        self.joinStarted();
        if (self.failed.load(.acquire)) return error.WorkerFailed;
    }
    pub fn outstanding(self: *const WorkflowSubsystem) usize {
        var count: usize = 0;
        for (self.threads) |thread| if (thread != null) {
            count += 1;
        };
        return count;
    }
    fn joinStarted(self: *WorkflowSubsystem) void {
        for (self.threads) |*thread| if (thread.*) |value| {
            value.join();
            thread.* = null;
        };
    }
    fn run(self: *WorkflowSubsystem, index: usize) void {
        defer self.done[index].set();
        const activity_start = self.counts[0];
        const timer_start = activity_start + self.counts[1];
        const publisher_start = timer_start + self.counts[2];
        while (!self.stopping.load(.acquire)) {
            const worked = (if (index < activity_start)
                self.workflow.runOne()
            else if (index < timer_start)
                self.activities.runOne()
            else if (index < publisher_start)
                self.timers.runOne()
            else
                self.publisher.runOne()) catch {
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
