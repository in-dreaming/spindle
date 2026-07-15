const Task = @import("task.zig").Task;
const Counter = @import("counter.zig").Counter;
const Executor = @import("executor.zig").Executor;
const SubmitOptions = @import("executor.zig").SubmitOptions;
const CancellationSource = @import("cancellation.zig").CancellationSource;
const AdaptiveMutex = @import("../sync/adaptive_mutex.zig").AdaptiveMutex;

pub const ScopePolicy = enum { collect_all, cancel_on_first_error, ignore_errors };

/// Structured task lifetime. All successfully spawned tasks are joined by `wait` before scope teardown.
pub const Scope = struct {
    executor: Executor,
    policy: ScopePolicy = .collect_all,
    counter: Counter = .{},
    cancellation: CancellationSource = .{},
    lock: AdaptiveMutex = .{},
    tasks: ?*Task = null,
    failed: bool = false,
    pub fn init(executor: Executor, policy: ScopePolicy) Scope {
        return .{ .executor = executor, .policy = policy };
    }
    pub fn spawn(self: *Scope, task: *Task) !void {
        if (task.complete_fn != null) return error.TaskAlreadyOwned;
        self.counter.add(1);
        self.lock.lock();
        task.next = self.tasks;
        self.tasks = task;
        self.lock.unlock();
        task.complete_fn = completed;
        task.completion_context = self;
        self.executor.submit(task, .{}) catch |err| {
            task.complete_fn = null;
            task.completion_context = null;
            self.counter.complete();
            return err;
        };
    }
    pub fn wait(self: *Scope) !void {
        try self.counter.wait();
        if (self.policy != .ignore_errors and self.failed) return error.TaskFailed;
    }
    pub fn cancel(self: *Scope) void {
        self.cancellation.cancel();
    }
    fn completed(task: *Task) void {
        const self: *Scope = @ptrCast(@alignCast(task.completion_context.?));
        if (task.status() == .failed) {
            self.lock.lock();
            const first = !self.failed;
            self.failed = true;
            self.lock.unlock();
            if (first and self.policy == .cancel_on_first_error) self.cancelPending();
        }
        self.counter.complete();
    }
    fn cancelPending(self: *Scope) void {
        self.cancellation.cancel();
        self.lock.lock();
        const tasks = self.tasks;
        self.lock.unlock();
        var cursor = tasks;
        while (cursor) |task| : (cursor = task.next) _ = task.cancel();
    }
};
