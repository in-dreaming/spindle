const std = @import("std");
const Task = @import("task.zig").Task;
const api = @import("executor.zig");
const MpmcQueue = @import("../concurrent/mpmc_queue.zig").MpmcQueue;
/// Caller-thread executor. Only `drain` executes queued work.
pub const PumpExecutor = struct {
    queue: MpmcQueue(*Task),
    accepting: bool = true,
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !PumpExecutor {
        return .{ .queue = try MpmcQueue(*Task).init(allocator, capacity) };
    }
    pub fn deinit(self: *PumpExecutor) void {
        self.shutdown(.cancel_pending);
        self.queue.deinit(dispose);
    }
    pub fn executor(self: *PumpExecutor) api.Executor {
        return .{ .context = self, .submit_fn = erasedSubmit, .worker_count_fn = workers, .is_worker_fn = worker, .help_until_fn = help };
    }
    pub fn submit(self: *PumpExecutor, task: *Task, _: api.SubmitOptions) api.SubmitError!void {
        if (!self.accepting) return error.Shutdown;
        if (!task.tryQueue()) return error.DuplicateSubmission;
        task.retainQueueReference();
        self.queue.tryPush(task) catch |err| switch (err) {
            error.Full => {
                _ = task.state.cmpxchgStrong(.queued, .created, .acq_rel, .acquire);
                task.releaseQueueReference();
                return error.Backpressure;
            },
            error.Closed => {
                task.releaseQueueReference();
                return error.Shutdown;
            },
        };
    }
    pub fn drain(self: *PumpExecutor, max_tasks: usize) usize {
        var count: usize = 0;
        while (count < max_tasks) {
            const task = self.queue.tryPop() catch break;
            task.execute();
            task.releaseQueueReference();
            count += 1;
        }
        return count;
    }
    /// Drains at most `max_tasks`, stopping when the monotonic awake-clock budget expires.
    pub fn drainFor(self: *PumpExecutor, max_tasks: usize, budget_ns: u64) usize {
        const deadline = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).addDuration(.{ .raw = .{ .nanoseconds = budget_ns }, .clock = .awake });
        var count: usize = 0;
        while (count < max_tasks and std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds < deadline.raw.nanoseconds) {
            const task = self.queue.tryPop() catch break;
            task.execute();
            task.releaseQueueReference();
            count += 1;
        }
        return count;
    }
    pub fn shutdown(self: *PumpExecutor, policy: api.ShutdownPolicy) void {
        if (!self.accepting) return;
        self.accepting = false;
        self.queue.close();
        if (policy != .drain) {
            while (true) {
                const task = self.queue.tryPop() catch break;
                _ = task.cancel();
                task.releaseQueueReference();
            }
        } else _ = self.drain(std.math.maxInt(usize));
    }
    fn dispose(task: *Task) void {
        _ = task.cancel();
        task.releaseQueueReference();
    }
    fn erasedSubmit(context: *anyopaque, task: *Task, opts: api.SubmitOptions) api.SubmitError!void {
        const self: *PumpExecutor = @ptrCast(@alignCast(context));
        try self.submit(task, opts);
    }
    fn workers(_: *anyopaque) usize {
        return 0;
    }
    fn worker(_: *anyopaque) bool {
        return false;
    }
    fn help(context: *anyopaque, predicate: *const fn () bool) void {
        const self: *PumpExecutor = @ptrCast(@alignCast(context));
        while (!predicate() and self.drain(1) != 0) {}
    }
};
