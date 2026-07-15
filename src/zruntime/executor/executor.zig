const Task = @import("task.zig").Task;
const std = @import("std");
const AdaptiveMutex = @import("../sync/adaptive_mutex.zig").AdaptiveMutex;

pub const SubmitOptions = struct {};
pub const SubmitError = error{ Rejected, DuplicateSubmission, Backpressure, Shutdown };
pub const ShutdownPolicy = enum { drain, cancel_pending, immediate };
pub const ExecutorId = packed struct { slot: u32, generation: u32 };

/// Process-local target registry. IDs are invalid after unregister or registry deinitialization.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    lock: AdaptiveMutex = .{},
    const Entry = struct { generation: u32 = 1, executor: ?Executor = null };
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *Registry, executor: Executor) !ExecutorId {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.entries.items, 0..) |*entry, index| if (entry.executor == null) {
            entry.executor = executor;
            return .{ .slot = @intCast(index), .generation = entry.generation };
        };
        try self.entries.append(self.allocator, .{ .executor = executor });
        return .{ .slot = @intCast(self.entries.items.len - 1), .generation = 1 };
    }
    pub fn unregister(self: *Registry, id: ExecutorId) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (id.slot >= self.entries.items.len) return false;
        const entry = &self.entries.items[id.slot];
        if (entry.generation != id.generation or entry.executor == null) return false;
        entry.executor = null;
        entry.generation +%= 1;
        if (entry.generation == 0) entry.generation = 1;
        return true;
    }
    pub fn resolve(self: *Registry, id: ExecutorId) ?Executor {
        self.lock.lock();
        defer self.lock.unlock();
        if (id.slot >= self.entries.items.len) return null;
        const entry = self.entries.items[id.slot];
        if (entry.generation != id.generation) return null;
        return entry.executor;
    }
};

/// Type-erased, non-owning executor view. The concrete executor must outlive this value.
pub const Executor = struct {
    context: *anyopaque,
    submit_fn: *const fn (*anyopaque, *Task, SubmitOptions) SubmitError!void,
    worker_count_fn: *const fn (*anyopaque) usize,
    is_worker_fn: *const fn (*anyopaque) bool,
    help_until_fn: *const fn (*anyopaque, *const fn () bool) void,
    pub fn submit(self: Executor, task: *Task, options: SubmitOptions) SubmitError!void {
        try self.submit_fn(self.context, task, options);
    }
    pub fn workerCount(self: Executor) usize {
        return self.worker_count_fn(self.context);
    }
    pub fn isWorkerThread(self: Executor) bool {
        return self.is_worker_fn(self.context);
    }
    pub fn helpUntil(self: Executor, predicate: *const fn () bool) void {
        self.help_until_fn(self.context, predicate);
    }
};
