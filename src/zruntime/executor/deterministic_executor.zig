const std = @import("std");
const Task = @import("task.zig").Task;
const api = @import("executor.zig");

pub const EventKind = enum(u8) { ready, selected, steal };
pub const Event = struct { kind: EventKind, task_id: u64 };
pub const Log = struct {
    version: u32 = 1,
    events: []Event,
    checksum: u64,
    pub fn deinit(self: *Log, allocator: std.mem.Allocator) void {
        allocator.free(self.events);
        self.* = undefined;
    }
};

/// Single-threaded stable scheduler for recording and validating scheduling decisions.
/// Replay compares both event kind and caller-provided stable task IDs and rejects any divergence.
pub const DeterministicExecutor = struct {
    allocator: std.mem.Allocator,
    ready: std.ArrayListUnmanaged(Entry) = .empty,
    recorded: std.ArrayListUnmanaged(Event) = .empty,
    replay: ?[]const Event = null,
    replay_index: usize = 0,
    next_id: u64 = 1,
    accepting: bool = true,
    const Entry = struct { task: *Task, id: u64 };
    pub fn init(allocator: std.mem.Allocator) DeterministicExecutor {
        return .{ .allocator = allocator };
    }
    pub fn initReplay(allocator: std.mem.Allocator, log: *const Log) !DeterministicExecutor {
        if (log.version != 1 or checksum(log.events) != log.checksum) return error.InvalidReplayLog;
        return .{ .allocator = allocator, .replay = log.events };
    }
    pub fn deinit(self: *DeterministicExecutor) void {
        for (self.ready.items) |entry| {
            _ = entry.task.cancel();
            entry.task.releaseQueueReference();
        }
        self.ready.deinit(self.allocator);
        self.recorded.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn executor(self: *DeterministicExecutor) api.Executor {
        return .{ .context = self, .submit_fn = erasedSubmit, .worker_count_fn = erasedWorkers, .is_worker_fn = erasedWorker, .help_until_fn = erasedHelp };
    }
    pub fn submit(self: *DeterministicExecutor, task: *Task, _: api.SubmitOptions) api.SubmitError!void {
        const id = self.next_id;
        self.next_id += 1;
        self.submitWithId(task, id) catch |err| switch (err) {
            error.OutOfMemory => return error.Backpressure,
            error.ReplayMismatch, error.ReplayExhausted => return error.Rejected,
            else => return error.Rejected,
        };
    }
    pub fn submitWithId(self: *DeterministicExecutor, task: *Task, id: u64) !void {
        if (!self.accepting) return error.Shutdown;
        if (!task.tryQueue()) return error.DuplicateSubmission;
        errdefer _ = task.state.cmpxchgStrong(.queued, .created, .acq_rel, .acquire);
        try self.expect(.ready, id);
        task.retainQueueReference();
        errdefer task.releaseQueueReference();
        try self.ready.append(self.allocator, .{ .task = task, .id = id });
    }
    pub fn runOne(self: *DeterministicExecutor) !bool {
        if (self.ready.items.len == 0) return false;
        const entry = self.ready.orderedRemove(0);
        try self.expect(.selected, entry.id);
        entry.task.execute();
        entry.task.releaseQueueReference();
        return true;
    }
    pub fn run(self: *DeterministicExecutor) !void {
        while (try self.runOne()) {}
    }
    pub fn finishReplay(self: *const DeterministicExecutor) !void {
        if (self.replay) |events| if (self.replay_index != events.len) return error.ReplayTruncated;
    }
    pub fn recordLog(self: *const DeterministicExecutor) !Log {
        const events = try self.allocator.dupe(Event, self.recorded.items);
        return .{ .events = events, .checksum = checksum(events) };
    }
    pub fn shutdown(self: *DeterministicExecutor, _: api.ShutdownPolicy) void {
        self.accepting = false;
    }
    pub fn isWorkerThread(_: *const DeterministicExecutor) bool {
        return true;
    }
    pub fn helpUntil(self: *DeterministicExecutor, context: *anyopaque, predicate: *const fn (*anyopaque) bool) void {
        while (!predicate(context)) {
            _ = self.runOne() catch return;
        }
    }
    fn expect(self: *DeterministicExecutor, kind: EventKind, id: u64) !void {
        if (self.replay) |events| {
            if (self.replay_index == events.len) return error.ReplayExhausted;
            const actual = events[self.replay_index];
            if (actual.kind != kind or actual.task_id != id) return error.ReplayMismatch;
            self.replay_index += 1;
        } else try self.recorded.append(self.allocator, .{ .kind = kind, .task_id = id });
    }
    fn checksum(events: []const Event) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        for (events) |event| {
            hash = (hash ^ @intFromEnum(event.kind)) *% 0x100000001b3;
            hash = (hash ^ event.task_id) *% 0x100000001b3;
        }
        return hash;
    }
    fn erasedSubmit(context: *anyopaque, task: *Task, options: api.SubmitOptions) api.SubmitError!void {
        try (@as(*DeterministicExecutor, @ptrCast(@alignCast(context)))).submit(task, options);
    }
    fn erasedWorkers(_: *anyopaque) usize {
        return 1;
    }
    fn erasedWorker(_: *anyopaque) bool {
        return true;
    }
    fn erasedHelp(context: *anyopaque, predicate_context: *anyopaque, predicate: *const fn (*anyopaque) bool) void {
        (@as(*DeterministicExecutor, @ptrCast(@alignCast(context)))).helpUntil(predicate_context, predicate);
    }
};
