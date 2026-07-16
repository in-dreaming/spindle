const std = @import("std");
const Task = @import("task.zig").Task;
const api = @import("executor.zig");
const MpmcQueue = @import("../concurrent/mpmc_queue.zig").MpmcQueue;
const Thread = @import("../platform/thread.zig");
const Event = @import("../sync/event.zig").Event;
const park = @import("../platform/park.zig");
threadlocal var worker_state: ?*anyopaque = null;

/// Fixed-size compute pool. Tasks run on dedicated worker threads; completion order is unspecified.
pub const FixedPool = struct {
    state: *State,
    const State = struct {
        allocator: std.mem.Allocator,
        queue: MpmcQueue(*Task),
        threads: []Thread.Thread,
        accepting: std.atomic.Value(bool) = .init(true),
        stopping: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(usize) = .init(0),
        done: Event = Event.init(.manual, false),
        joined: std.atomic.Value(bool) = .init(false),
    };

    pub fn init(allocator: std.mem.Allocator, workers: usize, queue_capacity: usize) !FixedPool {
        if (workers == 0) return error.InvalidWorkerCount;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{ .allocator = allocator, .queue = try MpmcQueue(*Task).init(allocator, queue_capacity), .threads = try allocator.alloc(Thread.Thread, workers) };
        errdefer {
            state.queue.deinit(disposeTask);
            allocator.free(state.threads);
        }
        var started: usize = 0;
        errdefer for (state.threads[0..started]) |thread| thread.join();
        for (state.threads) |*thread| {
            thread.* = try Thread.spawn(.{}, workerMain, .{state});
            started += 1;
        }
        return .{ .state = state };
    }
    pub fn deinit(self: *FixedPool) void {
        self.shutdown(.cancel_pending);
        self.state.queue.deinit(disposeTask);
        self.state.allocator.free(self.state.threads);
        self.state.allocator.destroy(self.state);
    }
    pub fn executor(self: *FixedPool) api.Executor {
        return .{ .context = self, .submit_fn = erasedSubmit, .worker_count_fn = erasedWorkers, .is_worker_fn = erasedWorker, .help_until_fn = erasedHelp };
    }
    pub fn submit(self: *FixedPool, task: *Task, _: api.SubmitOptions) api.SubmitError!void {
        if (!self.state.accepting.load(.acquire)) return error.Shutdown;
        if (!task.tryQueue()) return error.DuplicateSubmission;
        task.retainQueueReference();
        while (true) {
            self.state.queue.tryPush(task) catch |err| switch (err) {
                error.Full => {
                    if (!self.isWorkerThread()) {
                        _ = task.state.cmpxchgStrong(.queued, .created, .acq_rel, .acquire);
                        task.releaseQueueReference();
                        return error.Backpressure;
                    }
                    const helping = self.state.queue.tryPop() catch {
                        std.Thread.yield() catch {};
                        continue;
                    };
                    helping.execute();
                    helping.releaseQueueReference();
                    continue;
                },
                error.Closed => {
                    task.releaseQueueReference();
                    return error.Shutdown;
                },
            };
            break;
        }
    }
    pub fn requestStop(self: *FixedPool, policy: api.ShutdownPolicy) void {
        if (self.state.stopping.swap(true, .acq_rel)) return;
        self.state.accepting.store(false, .release);
        if (policy != .drain) self.cancelPending();
        self.state.queue.close();
    }
    pub fn wait(self: *FixedPool, deadline: ?park.Deadline) error{Timeout}!void {
        if (!self.state.stopping.load(.acquire)) return;
        self.state.done.wait(deadline, .{}) catch return error.Timeout;
        if (!self.state.joined.swap(true, .acq_rel)) for (self.state.threads) |thread| thread.join();
    }
    pub fn outstandingWorkers(self: *const FixedPool) usize {
        return self.state.threads.len - self.state.finished.load(.acquire);
    }
    pub fn shutdown(self: *FixedPool, policy: api.ShutdownPolicy) void {
        self.requestStop(policy);
        self.wait(null) catch unreachable;
    }
    fn cancelPending(self: *FixedPool) void {
        while (true) {
            const task = self.state.queue.tryPop() catch break;
            _ = task.cancel();
            task.releaseQueueReference();
        }
    }
    pub fn isWorkerThread(self: *const FixedPool) bool {
        return worker_state == @as(*anyopaque, @ptrCast(self.state));
    }
    pub fn helpUntil(self: *FixedPool, context: *anyopaque, predicate: *const fn (*anyopaque) bool) void {
        while (!predicate(context)) {
            const task = self.state.queue.tryPop() catch {
                std.Thread.yield() catch {};
                continue;
            };
            task.execute();
            task.releaseQueueReference();
        }
    }
    fn workerMain(state: *State) void {
        worker_state = @ptrCast(state);
        defer {
            worker_state = null;
            if (state.finished.fetchAdd(1, .acq_rel) + 1 == state.threads.len) state.done.set();
        }
        while (true) {
            const task = state.queue.tryPop() catch |err| switch (err) {
                error.Empty => {
                    if (state.stopping.load(.acquire)) break;
                    std.Thread.yield() catch {};
                    continue;
                },
                error.Closed => break,
            };
            task.execute();
            task.releaseQueueReference();
        }
    }
    fn disposeTask(task: *Task) void {
        _ = task.cancel();
        task.releaseQueueReference();
    }
    fn erasedSubmit(context: *anyopaque, task: *Task, options: api.SubmitOptions) api.SubmitError!void {
        const self: *FixedPool = @ptrCast(@alignCast(context));
        try self.submit(task, options);
    }
    fn erasedWorkers(context: *anyopaque) usize {
        const self: *FixedPool = @ptrCast(@alignCast(context));
        return self.state.threads.len;
    }
    fn erasedWorker(context: *anyopaque) bool {
        const self: *FixedPool = @ptrCast(@alignCast(context));
        return self.isWorkerThread();
    }
    fn erasedHelp(context: *anyopaque, predicate_context: *anyopaque, predicate: *const fn (*anyopaque) bool) void {
        const self: *FixedPool = @ptrCast(@alignCast(context));
        self.helpUntil(predicate_context, predicate);
    }
};
