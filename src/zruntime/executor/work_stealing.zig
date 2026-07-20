const std = @import("std");
const Task = @import("task.zig").Task;
const Priority = @import("task.zig").Priority;
const api = @import("executor.zig");
const MpmcQueue = @import("../concurrent/mpmc_queue.zig").MpmcQueue;
const Deque = @import("../concurrent/work_stealing_deque.zig").WorkStealingDeque;
const Semaphore = @import("../sync/semaphore.zig").Semaphore;
const Thread = @import("../platform/thread.zig");

threadlocal var current_worker: ?*anyopaque = null;

pub const Config = struct {
    workers: usize,
    local_capacity: usize = 256,
    injection_capacity: usize = 1024,
    urgent_capacity: usize = 256,
    high_skip_limit: u8 = 8,
    normal_skip_limit: u8 = 16,
};

pub const WorkerStats = struct { executed: u64, stolen: u64, idle: u64 };

/// A fixed-size CPU executor with owner-local queues, bounded global injection, and cooperative waiting.
/// Tasks are caller-owned and must outlive completion; shutdown joins every worker before returning.
pub const WorkStealingExecutor = struct {
    state: *State,
    const Worker = struct {
        id: usize,
        state: *State,
        high: Deque(*Task),
        normal: Deque(*Task),
        background: Deque(*Task),
        rng: std.Random.DefaultPrng,
        high_skips: u8 = 0,
        normal_skips: u8 = 0,
        executed: std.atomic.Value(u64) = .init(0),
        stolen: std.atomic.Value(u64) = .init(0),
        idle: std.atomic.Value(u64) = .init(0),
    };
    const State = struct {
        allocator: std.mem.Allocator,
        workers: []Worker,
        threads: []Thread.Thread,
        injection: MpmcQueue(*Task),
        urgent: MpmcQueue(*Task),
        wake: Semaphore,
        accepting: std.atomic.Value(bool) = .init(true),
        stopping: std.atomic.Value(bool) = .init(false),
        sleeping: std.atomic.Value(usize) = .init(0),
        config: Config,
    };

    pub fn init(allocator: std.mem.Allocator, config: Config) !WorkStealingExecutor {
        if (config.workers == 0) return error.InvalidWorkerCount;
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
            .allocator = allocator,
            .workers = try allocator.alloc(Worker, config.workers),
            .threads = try allocator.alloc(Thread.Thread, config.workers),
            .injection = try MpmcQueue(*Task).init(allocator, config.injection_capacity),
            .urgent = try MpmcQueue(*Task).init(allocator, config.urgent_capacity),
            .wake = try Semaphore.init(0, @intCast(config.workers)),
            .config = config,
        };
        errdefer {
            state.injection.deinit(disposeTask);
            state.urgent.deinit(disposeTask);
            allocator.free(state.threads);
            allocator.free(state.workers);
        }
        for (state.workers, 0..) |*worker, id| worker.* = .{
            .id = id,
            .state = state,
            .high = try Deque(*Task).init(allocator, config.local_capacity),
            .normal = try Deque(*Task).init(allocator, config.local_capacity),
            .background = try Deque(*Task).init(allocator, config.local_capacity),
            .rng = std.Random.DefaultPrng.init(@as(u64, @intCast(id + 1))),
        };
        var started: usize = 0;
        errdefer for (state.threads[0..started]) |thread| thread.join();
        for (state.threads, 0..) |*thread, id| {
            thread.* = try Thread.spawn(.{}, workerMain, .{&state.workers[id]});
            started += 1;
        }
        return .{ .state = state };
    }
    pub fn deinit(self: *WorkStealingExecutor) void {
        self.shutdown(.cancel_pending);
        for (self.state.workers) |*worker| {
            worker.high.deinit(disposeTask);
            worker.normal.deinit(disposeTask);
            worker.background.deinit(disposeTask);
        }
        self.state.injection.deinit(disposeTask);
        self.state.urgent.deinit(disposeTask);
        self.state.allocator.free(self.state.threads);
        self.state.allocator.free(self.state.workers);
        self.state.allocator.destroy(self.state);
    }
    pub fn executor(self: *WorkStealingExecutor) api.Executor {
        return .{ .context = self, .submit_fn = erasedSubmit, .worker_count_fn = erasedWorkers, .is_worker_fn = erasedWorker, .help_until_fn = erasedHelp };
    }
    pub fn submit(self: *WorkStealingExecutor, task: *Task, _: api.SubmitOptions) api.SubmitError!void {
        if (!self.state.accepting.load(.acquire)) return error.Shutdown;
        if (!task.tryQueue()) return error.DuplicateSubmission;
        task.retainQueueReference();
        self.enqueue(task) catch |err| {
            task.releaseQueueReference();
            _ = task.state.cmpxchgStrong(.queued, .created, .acq_rel, .acquire);
            return err;
        };
    }
    fn enqueue(self: *WorkStealingExecutor, task: *Task) api.SubmitError!void {
        if (currentWorker()) |worker| if (worker.state == self.state) {
            if (task.priority == .critical) return self.pushInjection(task);
            self.pushLocal(worker, task) catch |err| switch (err) {
                error.Full => try self.pushInjection(task),
                error.Closed => return error.Shutdown,
                error.NotOwner => return error.Backpressure,
            };
            return;
        };
        try self.pushInjection(task);
    }
    fn pushLocal(self: *WorkStealingExecutor, worker: *Worker, task: *Task) error{ Full, Closed, NotOwner }!void {
        switch (task.priority) {
            .high => try worker.high.pushBottom(task),
            .low => try worker.background.pushBottom(task),
            .normal => try worker.normal.pushBottom(task),
            .critical => try worker.high.pushBottom(task),
        }
        self.wakeForWork(1);
    }
    fn pushInjection(self: *WorkStealingExecutor, task: *Task) api.SubmitError!void {
        const queue = if (task.priority == .critical) &self.state.urgent else &self.state.injection;
        queue.tryPush(task) catch |err| switch (err) {
            error.Full => return error.Backpressure,
            error.Closed => return error.Shutdown,
        };
        self.wakeForWork(1);
    }
    fn wakeForWork(self: *WorkStealingExecutor, added: usize) void {
        const sleepers = self.state.sleeping.load(.acquire);
        const count: u32 = @intCast(@min(added, sleepers));
        for (0..count) |_| self.state.wake.release(1) catch break;
    }
    pub fn shutdown(self: *WorkStealingExecutor, policy: api.ShutdownPolicy) void {
        if (self.state.stopping.swap(true, .acq_rel)) return;
        self.state.accepting.store(false, .release);
        self.state.injection.close();
        self.state.urgent.close();
        if (policy != .drain) self.cancelPending();
        for (self.state.threads) |_| self.state.wake.release(1) catch break;
        for (self.state.threads) |thread| thread.join();
    }
    fn cancelPending(self: *WorkStealingExecutor) void {
        drainQueue(&self.state.injection);
        drainQueue(&self.state.urgent);
        for (self.state.workers) |*worker| {
            drainDeque(&worker.high);
            drainDeque(&worker.normal);
            drainDeque(&worker.background);
        }
    }
    pub fn isWorkerThread(self: *const WorkStealingExecutor) bool {
        return if (currentWorker()) |worker| worker.state == self.state else false;
    }
    pub fn helpUntil(self: *WorkStealingExecutor, context: *anyopaque, predicate: *const fn (*anyopaque) bool) void {
        while (!predicate(context)) {
            if (!self.tryExecuteOne()) std.Thread.yield() catch {};
        }
    }
    pub fn tryExecuteOne(self: *WorkStealingExecutor) bool {
        const worker = currentWorker() orelse return false;
        if (worker.state != self.state) return false;
        if (takeTask(worker)) |task| {
            task.releaseQueueReference();
            task.execute();
            _ = worker.executed.fetchAdd(1, .monotonic);
            return true;
        }
        return false;
    }
    pub fn workerStats(self: *const WorkStealingExecutor, id: usize) WorkerStats {
        const worker = &self.state.workers[id];
        return .{ .executed = worker.executed.load(.monotonic), .stolen = worker.stolen.load(.monotonic), .idle = worker.idle.load(.monotonic) };
    }
    fn workerMain(worker: *Worker) void {
        current_worker = @ptrCast(worker);
        defer current_worker = null;
        while (true) {
            if (takeTask(worker)) |task| {
                task.releaseQueueReference();
                task.execute();
                _ = worker.executed.fetchAdd(1, .monotonic);
                continue;
            }
            if (worker.state.stopping.load(.acquire)) break;
            var executed_during_spin = false;
            for (0..32) |_| {
                if (takeTask(worker)) |task| {
                    task.releaseQueueReference();
                    task.execute();
                    _ = worker.executed.fetchAdd(1, .monotonic);
                    executed_during_spin = true;
                    break;
                }
                std.atomic.spinLoopHint();
            }
            if (executed_during_spin) continue;
            _ = worker.idle.fetchAdd(1, .monotonic);
            _ = worker.state.sleeping.fetchAdd(1, .acq_rel);
            // Close the submit-vs-park window: a submit that observed no sleeper is now visible here.
            if (takeTask(worker)) |task| {
                _ = worker.state.sleeping.fetchSub(1, .acq_rel);
                task.releaseQueueReference();
                task.execute();
                _ = worker.executed.fetchAdd(1, .monotonic);
                continue;
            }
            if (!worker.state.stopping.load(.acquire)) worker.state.wake.acquire(null, .{}) catch {};
            _ = worker.state.sleeping.fetchSub(1, .acq_rel);
        }
    }
    fn takeTask(worker: *Worker) ?*Task {
        if (worker.state.urgent.tryPop()) |task| return task else |_| {}
        // Aging forces periodic service for normal and background work under a continuous high stream.
        if (worker.high_skips >= worker.state.config.high_skip_limit) {
            if (worker.normal.popBottom()) |task| {
                worker.high_skips = 0;
                return task;
            } else |_| {}
        }
        if (worker.normal_skips >= worker.state.config.normal_skip_limit) {
            if (worker.background.popBottom()) |task| {
                worker.normal_skips = 0;
                return task;
            } else |_| {}
        }
        if (worker.high.popBottom()) |task| {
            worker.high_skips +%= 1;
            worker.normal_skips +%= 1;
            return task;
        } else |_| {}
        if (worker.normal.popBottom()) |task| {
            worker.high_skips = 0;
            worker.normal_skips +%= 1;
            return task;
        } else |_| {}
        if (worker.background.popBottom()) |task| {
            worker.high_skips = 0;
            worker.normal_skips = 0;
            return task;
        } else |_| {}
        if (worker.state.injection.tryPop()) |task| return task else |_| {}
        const start = worker.rng.random().uintLessThan(usize, worker.state.workers.len);
        for (0..worker.state.workers.len) |offset| {
            const victim = &worker.state.workers[(start + offset) % worker.state.workers.len];
            if (victim == worker) continue;
            if (victim.high.stealTop()) |task| {
                _ = worker.stolen.fetchAdd(1, .monotonic);
                return task;
            } else |_| {}
            if (victim.normal.stealTop()) |task| {
                _ = worker.stolen.fetchAdd(1, .monotonic);
                return task;
            } else |_| {}
            if (victim.background.stealTop()) |task| {
                _ = worker.stolen.fetchAdd(1, .monotonic);
                return task;
            } else |_| {}
        }
        return null;
    }
    fn currentWorker() ?*Worker {
        const value = current_worker orelse return null;
        return @ptrCast(@alignCast(value));
    }
    fn drainQueue(queue: *MpmcQueue(*Task)) void {
        while (true) {
            const task = queue.tryPop() catch break;
            _ = task.cancel();
            task.releaseQueueReference();
        }
    }
    fn drainDeque(queue: *Deque(*Task)) void {
        while (true) {
            const task = queue.stealTop() catch break;
            _ = task.cancel();
            task.releaseQueueReference();
        }
    }
    fn disposeTask(task: *Task) void {
        _ = task.cancel();
        task.releaseQueueReference();
    }
    fn erasedSubmit(context: *anyopaque, task: *Task, options: api.SubmitOptions) api.SubmitError!void {
        try (@as(*WorkStealingExecutor, @ptrCast(@alignCast(context)))).submit(task, options);
    }
    fn erasedWorkers(context: *anyopaque) usize {
        return (@as(*WorkStealingExecutor, @ptrCast(@alignCast(context)))).state.threads.len;
    }
    fn erasedWorker(context: *anyopaque) bool {
        return (@as(*WorkStealingExecutor, @ptrCast(@alignCast(context)))).isWorkerThread();
    }
    fn erasedHelp(context: *anyopaque, predicate_context: *anyopaque, predicate: *const fn (*anyopaque) bool) void {
        (@as(*WorkStealingExecutor, @ptrCast(@alignCast(context)))).helpUntil(predicate_context, predicate);
    }
};
