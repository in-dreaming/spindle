const std = @import("std");
const Event = @import("../sync/event.zig").Event;

pub const State = enum(u8) { created, queued, running, completed, failed, cancelled };
pub const Priority = enum(u2) { low, normal, high, critical };
pub const Flags = packed struct(u8) { detached: bool = false, _reserved: u7 = 0 };

/// Intrusive, caller-owned work item. A Task must remain alive until it reaches a terminal state.
/// `run_fn` executes exactly once after a successful submission.
pub const Task = struct {
    next: ?*Task = null,
    run_fn: *const fn (*Task) void,
    context: ?*anyopaque = null,
    complete_fn: ?*const fn (*Task) void = null,
    completion_context: ?*anyopaque = null,
    priority: Priority = .normal,
    flags: Flags = .{},
    state: std.atomic.Value(State) = .init(.created),
    generation: std.atomic.Value(u32) = .init(1),
    queue_references: std.atomic.Value(u32) = .init(0),
    queue_released: Event = Event.init(.manual, true),
    done: Event = Event.init(.manual, false),

    pub fn init(run_fn: *const fn (*Task) void, context: ?*anyopaque) Task {
        return .{ .run_fn = run_fn, .context = context };
    }
    pub fn tryQueue(self: *Task) bool {
        return self.state.cmpxchgStrong(.created, .queued, .acq_rel, .acquire) == null;
    }
    pub fn cancel(self: *Task) bool {
        if (self.state.cmpxchgStrong(.queued, .cancelled, .acq_rel, .acquire) == null) {
            self.done.set();
            if (self.complete_fn) |callback| callback(self);
            return true;
        }
        return false;
    }
    pub fn execute(self: *Task) void {
        if (self.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire) != null) return;
        self.run_fn(self);
        if (self.state.load(.acquire) == .running) self.state.store(.completed, .release);
        self.done.set();
        if (self.complete_fn) |callback| callback(self);
    }
    pub fn wait(self: *Task) !void {
        try self.done.wait(null, .{});
    }
    pub fn status(self: *const Task) State {
        return self.state.load(.acquire);
    }
    /// Reuses a terminal caller-owned task. Existing TaskHandles become stale.
    pub fn reset(self: *Task) !void {
        switch (self.status()) {
            .completed, .failed, .cancelled => {},
            else => return error.TaskInFlight,
        }
        if (self.queue_references.load(.acquire) != 0) return error.TaskQueued;
        var next = self.generation.load(.acquire) +% 1;
        if (next == 0) next = 1;
        self.generation.store(next, .release);
        self.next = null;
        self.complete_fn = null;
        self.completion_context = null;
        self.done.reset();
        self.state.store(.created, .release);
    }
    pub fn handle(self: *Task) TaskHandle {
        return .{ .task = self, .generation = self.generation.load(.acquire) };
    }
    pub fn retainQueueReference(self: *Task) void {
        const previous = self.queue_references.fetchAdd(1, .acq_rel);
        if (previous == 0) self.queue_released.reset();
    }
    pub fn releaseQueueReference(self: *Task) void {
        const previous = self.queue_references.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous == 1) self.queue_released.set();
    }
    pub fn waitQueueReleased(self: *Task) !void {
        try self.queue_released.wait(null, .{});
    }
    /// Records a recoverable task failure from its running callback.
    pub fn fail(self: *Task) void {
        _ = self.state.cmpxchgStrong(.running, .failed, .acq_rel, .acquire);
    }
};

pub const TaskHandle = struct {
    task: *Task,
    generation: u32 = 1,
    pub fn wait(self: TaskHandle) error{StaleHandle}!void {
        if (!self.isValid()) return error.StaleHandle;
        try self.task.wait();
    }
    pub fn cancel(self: TaskHandle) bool {
        return self.isValid() and self.task.cancel();
    }
    pub fn status(self: TaskHandle) error{StaleHandle}!State {
        if (!self.isValid()) return error.StaleHandle;
        return self.task.status();
    }
    pub fn isValid(self: TaskHandle) bool {
        return self.task.generation.load(.acquire) == self.generation;
    }
};
