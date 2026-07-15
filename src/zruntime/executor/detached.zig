const std = @import("std");
const Task = @import("task.zig").Task;
const TaskHandle = @import("task.zig").TaskHandle;
const Executor = @import("executor.zig").Executor;
const AdaptiveMutex = @import("../sync/adaptive_mutex.zig").AdaptiveMutex;

pub const Allocation = struct { allocator: std.mem.Allocator, task: Task };

/// Explicit owner for detached work. Runtime shutdown calls `shutdown` to cancel queued work and join it.
pub const DetachedTracker = struct {
    allocator: std.mem.Allocator,
    lock: AdaptiveMutex = .{},
    allocations: std.ArrayListUnmanaged(*Allocation) = .empty,
    pub fn init(allocator: std.mem.Allocator) DetachedTracker {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *DetachedTracker) void {
        self.shutdown();
        self.allocations.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn shutdown(self: *DetachedTracker) void {
        self.lock.lock();
        const items = self.allocations.items;
        for (items) |allocation| _ = allocation.task.cancel();
        self.lock.unlock();
        for (items) |allocation| allocation.task.wait() catch {};
    }
    fn add(self: *DetachedTracker, allocation: *Allocation) !void {
        self.lock.lock();
        defer self.lock.unlock();
        try self.allocations.append(self.allocator, allocation);
    }
    fn remove(self: *DetachedTracker, allocation: *Allocation) void {
        self.lock.lock();
        defer self.lock.unlock();
        for (self.allocations.items, 0..) |item, index| if (item == allocation) {
            _ = self.allocations.swapRemove(index);
            return;
        };
    }
};

/// Owning handle for explicitly detached work. Deinit waits and releases the heap-owned task.
pub const DetachedHandle = struct {
    allocation: *Allocation,
    tracker: ?*DetachedTracker = null,
    pub fn wait(self: DetachedHandle) !void {
        try self.allocation.task.wait();
    }
    pub fn cancel(self: DetachedHandle) bool {
        return self.allocation.task.cancel();
    }
    pub fn taskHandle(self: DetachedHandle) TaskHandle {
        return self.allocation.task.handle();
    }
    pub fn deinit(self: *DetachedHandle) void {
        self.wait() catch {};
        self.allocation.task.waitQueueReleased() catch {};
        if (self.tracker) |tracker| tracker.remove(self.allocation);
        self.allocation.allocator.destroy(self.allocation);
    }
};

/// Submits heap-owned detached work. Prefer `submitTrackedDetached` for runtime-managed work.
pub fn submitDetached(allocator: std.mem.Allocator, executor: Executor, run_fn: *const fn (*Task) void, context: ?*anyopaque) !DetachedHandle {
    return submitTrackedDetached(null, allocator, executor, run_fn, context);
}
/// Registers detached work with an explicit shutdown owner before returning its handle.
pub fn submitTrackedDetached(tracker: ?*DetachedTracker, allocator: std.mem.Allocator, executor: Executor, run_fn: *const fn (*Task) void, context: ?*anyopaque) !DetachedHandle {
    const allocation = try allocator.create(Allocation);
    allocation.* = .{ .allocator = allocator, .task = Task.init(run_fn, context) };
    allocation.task.flags.detached = true;
    executor.submit(&allocation.task, .{}) catch |err| {
        allocator.destroy(allocation);
        return err;
    };
    if (tracker) |owner| owner.add(allocation) catch |err| {
        _ = allocation.task.cancel();
        allocation.task.wait() catch {};
        allocator.destroy(allocation);
        return err;
    };
    return .{ .allocation = allocation, .tracker = tracker };
}
