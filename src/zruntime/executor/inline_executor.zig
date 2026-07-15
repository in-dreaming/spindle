const Task = @import("task.zig").Task;
const api = @import("executor.zig");
/// Executes accepted tasks synchronously on the submitting thread.
pub const InlineExecutor = struct {
    accepting: bool = true,
    pub fn executor(self: *InlineExecutor) api.Executor {
        return .{ .context = self, .submit_fn = submitErased, .worker_count_fn = workers, .is_worker_fn = worker, .help_until_fn = help };
    }
    pub fn submit(self: *InlineExecutor, task: *Task, _: api.SubmitOptions) api.SubmitError!void {
        if (!self.accepting) return error.Shutdown;
        if (!task.tryQueue()) return error.DuplicateSubmission;
        task.execute();
    }
    pub fn shutdown(self: *InlineExecutor, _: api.ShutdownPolicy) void {
        self.accepting = false;
    }
    fn submitErased(context: *anyopaque, task: *Task, opts: api.SubmitOptions) api.SubmitError!void {
        const self: *InlineExecutor = @ptrCast(@alignCast(context));
        try self.submit(task, opts);
    }
    fn workers(_: *anyopaque) usize {
        return 0;
    }
    fn worker(_: *anyopaque) bool {
        return true;
    }
    fn help(_: *anyopaque, predicate: *const fn () bool) void {
        _ = predicate();
    }
};
