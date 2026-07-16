const std = @import("std");
const Task = @import("task.zig").Task;
const TaskHandle = @import("task.zig").TaskHandle;
const Executor = @import("executor.zig").Executor;
const AdaptiveMutex = @import("../sync/adaptive_mutex.zig").AdaptiveMutex;
const park = @import("../platform/park.zig");

const TrackerState = struct {
    allocator: std.mem.Allocator,
    lock: AdaptiveMutex = .{},
    allocations: std.ArrayListUnmanaged(*Allocation) = .empty,
    accepting: bool = true,
    refs: std.atomic.Value(usize) = .init(1),

    fn retain(self: *TrackerState) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }
    fn release(self: *TrackerState) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            self.allocations.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }
};

pub const Allocation = struct {
    allocator: std.mem.Allocator,
    task: Task,
    refs: std.atomic.Value(usize) = .init(1),
    link_lock: AdaptiveMutex = .{},
    tracker: ?*TrackerState = null,

    fn retain(self: *Allocation) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }
    fn release(self: *Allocation) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) self.allocator.destroy(self);
    }
};

/// Explicit owner for detached work. Its heap state remains stable when this value moves.
pub const DetachedTracker = struct {
    allocator: std.mem.Allocator,
    init_lock: AdaptiveMutex = .{},
    state: ?*TrackerState = null,

    pub fn init(allocator: std.mem.Allocator) DetachedTracker {
        return .{ .allocator = allocator };
    }
    fn ensureState(self: *DetachedTracker) !*TrackerState {
        self.init_lock.lock();
        defer self.init_lock.unlock();
        if (self.state) |state| return state;
        const state = try self.allocator.create(TrackerState);
        state.* = .{ .allocator = self.allocator };
        self.state = state;
        return state;
    }
    pub fn requestStop(self: *DetachedTracker) void {
        const state = self.state orelse return;
        state.lock.lock();
        state.accepting = false;
        for (state.allocations.items) |allocation| _ = allocation.task.cancel();
        state.lock.unlock();
    }
    pub fn wait(self: *DetachedTracker, deadline: ?park.Deadline) error{Timeout}!void {
        const state = self.state orelse return;
        state.lock.lock();
        defer state.lock.unlock();
        for (state.allocations.items) |allocation| {
            allocation.task.done.wait(deadline, .{}) catch return error.Timeout;
        }
    }
    pub fn shutdown(self: *DetachedTracker) void {
        self.requestStop();
        self.wait(null) catch unreachable;
    }
    pub fn outstanding(self: *DetachedTracker) usize {
        const state = self.state orelse return 0;
        state.lock.lock();
        defer state.lock.unlock();
        return state.allocations.items.len;
    }
    pub fn deinit(self: *DetachedTracker) void {
        const state = self.state orelse {
            self.* = undefined;
            return;
        };
        self.shutdown();
        while (true) {
            state.lock.lock();
            const allocation = if (state.allocations.items.len == 0) null else state.allocations.pop();
            const value = allocation orelse {
                state.lock.unlock();
                break;
            };
            value.link_lock.lock();
            if (value.tracker == state) value.tracker = null;
            value.link_lock.unlock();
            state.lock.unlock();
            value.release();
        }
        self.state = null;
        state.release();
        self.* = undefined;
    }
    fn add(self: *DetachedTracker, allocation: *Allocation) !void {
        const state = try self.ensureState();
        state.lock.lock();
        defer state.lock.unlock();
        if (!state.accepting) return error.Shutdown;
        try state.allocations.append(state.allocator, allocation);
        allocation.retain();
        allocation.link_lock.lock();
        allocation.tracker = state;
        allocation.link_lock.unlock();
    }
};

pub const DetachedHandle = struct {
    allocation: ?*Allocation,
    pub fn wait(self: DetachedHandle) !void {
        try self.allocation.?.task.wait();
    }
    pub fn cancel(self: DetachedHandle) bool {
        return self.allocation.?.task.cancel();
    }
    pub fn taskHandle(self: DetachedHandle) TaskHandle {
        return self.allocation.?.task.handle();
    }
    pub fn deinit(self: *DetachedHandle) void {
        const allocation = self.allocation orelse return;
        allocation.task.wait() catch {};
        allocation.task.waitQueueReleased() catch {};
        allocation.link_lock.lock();
        const state = allocation.tracker;
        if (state) |value| value.retain();
        allocation.link_lock.unlock();
        if (state) |value| {
            value.lock.lock();
            allocation.link_lock.lock();
            if (allocation.tracker == value) {
                allocation.tracker = null;
                for (value.allocations.items, 0..) |item, index| if (item == allocation) {
                    _ = value.allocations.swapRemove(index);
                    allocation.release();
                    break;
                };
            }
            allocation.link_lock.unlock();
            value.lock.unlock();
            value.release();
        }
        allocation.release();
        self.allocation = null;
    }
};

pub fn submitDetached(allocator: std.mem.Allocator, executor: Executor, run_fn: *const fn (*Task) void, context: ?*anyopaque) !DetachedHandle {
    return submitTrackedDetached(null, allocator, executor, run_fn, context);
}
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
        allocation.task.waitQueueReleased() catch {};
        allocator.destroy(allocation);
        return err;
    };
    return .{ .allocation = allocation };
}
