const std = @import("std");
const plan_mod = @import("plan.zig");
const budget_mod = @import("budget.zig");
const executor = @import("../executor/root.zig");
const Mutex = @import("../sync/adaptive_mutex.zig").AdaptiveMutex;
const EventSink = @import("../observability/event.zig").EventSink;
const cost_mod = @import("cost.zig");

pub const State = enum { pending, ready, budget_blocked, running, completed, cancelled, failed };
pub const Route = enum { compute, blocking, pump };
pub const TaskOptions = struct {
    cost: budget_mod.ResourceCost = .{},
    route: Route = .compute,
    /// Historical runtime estimate used only to order already-admissible work.
    estimate: ?*cost_mod.Estimate = null,
};
pub const Snapshot = struct { ready: usize, runnable: usize, running: usize, budget_blocked: usize, completed: usize, states: []const State };
pub const Metrics = struct { ready: u64, budget_blocked: u64, started: u64, completed: u64, failed: u64, released: u64 };

/// Executes a compiled resource plan. The caller owns all three executor instances.
pub const ExecutionHandle = struct {
    allocator: std.mem.Allocator,
    plan: *const plan_mod.CompiledResourcePlan,
    budget: *budget_mod.ExecutionBudget,
    executors: [3]executor.Executor,
    options: []const TaskOptions,
    states: []State,
    remaining: []usize,
    tasks: []executor.Task,
    items: []Item,
    downstream_unlock: []u32,
    sink: ?EventSink = null,
    metric_ready: std.atomic.Value(u64) = .init(0),
    metric_blocked: std.atomic.Value(u64) = .init(0),
    metric_started: std.atomic.Value(u64) = .init(0),
    metric_completed: std.atomic.Value(u64) = .init(0),
    metric_failed: std.atomic.Value(u64) = .init(0),
    metric_released: std.atomic.Value(u64) = .init(0),
    lock: Mutex = .{},
    cancelled: bool = false,
    pub fn deinit(self: *ExecutionHandle) void {
        self.allocator.free(self.items);
        self.allocator.free(self.downstream_unlock);
        self.allocator.free(self.tasks);
        self.allocator.free(self.remaining);
        self.allocator.free(self.states);
        self.allocator.destroy(self);
    }
    pub fn snapshot(self: *ExecutionHandle) Snapshot {
        self.lock.lock();
        defer self.lock.unlock();
        var result: Snapshot = .{ .ready = 0, .runnable = 0, .running = 0, .budget_blocked = 0, .completed = 0, .states = self.states };
        for (self.states) |state| switch (state) {
            .ready => {
                result.ready += 1;
                result.runnable += 1;
            },
            .budget_blocked => result.budget_blocked += 1,
            .running => result.running += 1,
            .completed => result.completed += 1,
            else => {},
        };
        return result;
    }
    pub fn metrics(self: *const ExecutionHandle) Metrics {
        return .{ .ready = self.metric_ready.load(.monotonic), .budget_blocked = self.metric_blocked.load(.monotonic), .started = self.metric_started.load(.monotonic), .completed = self.metric_completed.load(.monotonic), .failed = self.metric_failed.load(.monotonic), .released = self.metric_released.load(.monotonic) };
    }
    fn event(self: *ExecutionHandle, kind: []const u8, value: i64) void {
        self.sink.emit(.{ .monotonic_ns = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds, .kind = kind, .value = value });
    }
    pub fn cancel(self: *ExecutionHandle) void {
        self.lock.lock();
        self.cancelled = true;
        for (self.states) |*state| {
            if (state.* == .ready or state.* == .budget_blocked) state.* = .cancelled;
        }
        self.lock.unlock();
    }
    fn taskRun(task: *executor.Task) void {
        const item: *Item = @ptrCast(@alignCast(task.context.?));
        item.handle.runNode(item.index);
    }
    fn runNode(self: *ExecutionHandle, index: usize) void {
        const started_ns = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds;
        var failed = false;
        if (self.plan.nodes[index].task.run_result) |run| {
            run(self.plan.nodes[index].task.run_context) catch {
                failed = true;
            };
        } else if (self.plan.nodes[index].task.run) |run| run(self.plan.nodes[index].task.run_context);
        self.lock.lock();
        defer self.lock.unlock();
        self.budget.release(self.options[index].cost);
        if (self.options[index].estimate) |estimate| {
            const now_ns = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds;
            estimate.observe(@intCast(now_ns -| started_ns));
        }
        _ = self.metric_released.fetchAdd(1, .monotonic);
        self.event("resource_graph.release", @intCast(index));
        self.states[index] = if (failed) .failed else .completed;
        if (failed) {
            _ = self.metric_failed.fetchAdd(1, .monotonic);
            self.event("resource_graph.failed", @intCast(index));
            self.cancelled = true;
            for (self.states) |*state| {
                if (state.* == .ready or state.* == .budget_blocked or state.* == .pending) state.* = .cancelled;
            }
            return;
        }
        const node = self.plan.nodes[index];
        _ = self.metric_completed.fetchAdd(1, .monotonic);
        self.event("resource_graph.completed", @intCast(index));
        for (self.plan.dependents[node.dependent_start .. node.dependent_start + node.dependent_len]) |child| {
            self.remaining[child] -= 1;
            if (self.remaining[child] == 0 and !self.cancelled) {
                self.states[child] = .ready;
                _ = self.metric_ready.fetchAdd(1, .monotonic);
                self.event("resource_graph.ready", @intCast(child));
            }
        }
        self.dispatchLocked();
    }
    fn dispatchLocked(self: *ExecutionHandle) void {
        for (self.states) |*state| {
            if (state.* == .budget_blocked) state.* = .ready;
        }
        while (self.nextReady()) |index| {
            const state = &self.states[index];
            if (!self.budget.canEverFit(self.options[index].cost)) {
                state.* = .failed;
                _ = self.metric_failed.fetchAdd(1, .monotonic);
                self.event("resource_graph.unschedulable", @intCast(index));
                continue;
            }
            if (!self.budget.reserve(self.options[index].cost)) {
                state.* = .budget_blocked;
                _ = self.metric_blocked.fetchAdd(1, .monotonic);
                self.event("resource_graph.budget_blocked", @intCast(index));
                continue;
            }
            state.* = .running;
            _ = self.metric_started.fetchAdd(1, .monotonic);
            self.event("resource_graph.started", @intCast(index));
            const route: usize = @intFromEnum(self.options[index].route);
            self.executors[route].submit(&self.tasks[index], .{}) catch {
                self.budget.release(self.options[index].cost);
                state.* = .ready;
            };
        }
    }
    fn nextReady(self: *ExecutionHandle) ?usize {
        var selected: ?usize = null;
        for (self.states, 0..) |state, index| {
            if (state != .ready) continue;
            if (selected) |current| {
                const candidate = cost_mod.Score{ .node = @intCast(index), .downstream_unlock = self.downstream_unlock[index], .estimate = estimateFor(self.options[index]) };
                const existing = cost_mod.Score{ .node = @intCast(current), .downstream_unlock = self.downstream_unlock[current], .estimate = estimateFor(self.options[current]) };
                if (cost_mod.less({}, candidate, existing)) selected = index;
            } else selected = index;
        }
        return selected;
    }
};
fn estimateFor(options: TaskOptions) cost_mod.Estimate {
    return options.estimate orelse .{};
}
const Item = struct { handle: *ExecutionHandle, index: usize };

/// Starts a run and routes compute, blocking, and pump work through the supplied executors.
pub fn start(allocator: std.mem.Allocator, plan: *const plan_mod.CompiledResourcePlan, budget: *budget_mod.ExecutionBudget, compute: executor.Executor, blocking: executor.Executor, pump: executor.Executor, options: []const TaskOptions) !*ExecutionHandle {
    return startWithSink(allocator, plan, budget, compute, blocking, pump, options, null);
}
/// Starts a run with optional trace delivery. Event names are stable static identifiers.
pub fn startWithSink(allocator: std.mem.Allocator, plan: *const plan_mod.CompiledResourcePlan, budget: *budget_mod.ExecutionBudget, compute: executor.Executor, blocking: executor.Executor, pump: executor.Executor, options: []const TaskOptions, sink: ?EventSink) !*ExecutionHandle {
    if (options.len != plan.nodes.len) return error.InvalidTaskOptions;
    const handle = try allocator.create(ExecutionHandle);
    errdefer allocator.destroy(handle);
    const states = try allocator.alloc(State, plan.nodes.len);
    errdefer allocator.free(states);
    const remaining = try allocator.alloc(usize, plan.nodes.len);
    errdefer allocator.free(remaining);
    const tasks = try allocator.alloc(executor.Task, plan.nodes.len);
    errdefer allocator.free(tasks);
    const items = try allocator.alloc(Item, plan.nodes.len);
    errdefer allocator.free(items);
    const downstream_unlock = try allocator.alloc(u32, plan.nodes.len);
    errdefer allocator.free(downstream_unlock);
    handle.* = .{ .allocator = allocator, .plan = plan, .budget = budget, .executors = .{ compute, blocking, pump }, .options = options, .states = states, .remaining = remaining, .tasks = tasks, .items = items, .downstream_unlock = downstream_unlock, .sink = sink };
    for (plan.nodes, 0..) |node, i| {
        states[i] = if (node.dependency_len == 0) .ready else .pending;
        if (node.dependency_len == 0) _ = handle.metric_ready.fetchAdd(1, .monotonic);
        remaining[i] = node.dependency_len;
        items[i] = .{ .handle = handle, .index = i };
        tasks[i] = executor.Task.init(ExecutionHandle.taskRun, &items[i]);
    }
    for (0..plan.nodes.len) |offset| {
        const index = plan.nodes.len - 1 - offset;
        var score: u32 = 0;
        const node = plan.nodes[index];
        for (plan.dependents[node.dependent_start .. node.dependent_start + node.dependent_len]) |child| score += 1 + downstream_unlock[child];
        downstream_unlock[index] = score;
    }
    handle.lock.lock();
    handle.dispatchLocked();
    handle.lock.unlock();
    return handle;
}

const Probe = struct {
    value: *std.atomic.Value(u32),
    fn run(context: ?*anyopaque) void {
        const self: *Probe = @ptrCast(@alignCast(context.?));
        _ = self.value.fetchAdd(1, .acq_rel);
    }
};

test "scheduler separates ready from budget runnable and uses pump routing" {
    const builder_mod = @import("dependency_builder.zig");
    var graph = builder_mod.ResourceTaskGraph.init(std.testing.allocator);
    defer graph.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var left = Probe{ .value = &value };
    var right = Probe{ .value = &value };
    const first = try graph.addTask(.{ .name = "first", .run_context = &left, .run = Probe.run });
    const second = try graph.addTask(.{ .name = "second", .run_context = &right, .run = Probe.run });
    try graph.dependsOn(second, first);
    var compiled = try graph.compile(std.testing.allocator);
    defer compiled.deinit();
    var pump = try executor.PumpExecutor.init(std.testing.allocator, 4);
    defer pump.deinit();
    var budget = budget_mod.ExecutionBudget.init(.{ .memory = 1 });
    const options = [_]TaskOptions{ .{ .cost = .{ .memory = 1 }, .route = .pump }, .{ .cost = .{ .memory = 1 }, .route = .pump } };
    var handle = try start(std.testing.allocator, &compiled, &budget, pump.executor(), pump.executor(), pump.executor(), &options);
    defer handle.deinit();
    try std.testing.expectEqual(@as(usize, 1), handle.snapshot().running);
    _ = pump.drain(8);
    try std.testing.expectEqual(@as(u32, 2), value.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), handle.snapshot().completed);
    try std.testing.expectEqual(@as(u64, 0), budget.snapshot().memory);
}

test "scheduler emits lifecycle trace events and metrics" {
    const builder_mod = @import("dependency_builder.zig");
    const observability = @import("../observability/event.zig");
    var graph = builder_mod.ResourceTaskGraph.init(std.testing.allocator);
    defer graph.deinit();
    var value: std.atomic.Value(u32) = .init(0);
    var probe = Probe{ .value = &value };
    _ = try graph.addTask(.{ .name = "one", .run_context = &probe, .run = Probe.run });
    var compiled = try graph.compile(std.testing.allocator);
    defer compiled.deinit();
    var pump = try executor.PumpExecutor.init(std.testing.allocator, 2);
    defer pump.deinit();
    var budget = budget_mod.ExecutionBudget.init(.{ .memory = 1 });
    var events: [8]observability.Event = undefined;
    var ring = observability.RingSink.init(&events);
    const options = [_]TaskOptions{.{ .cost = .{ .memory = 1 }, .route = .pump }};
    var handle = try startWithSink(std.testing.allocator, &compiled, &budget, pump.executor(), pump.executor(), pump.executor(), &options, ring.sink());
    defer handle.deinit();
    _ = pump.drain(2);
    try std.testing.expectEqual(@as(u64, 1), handle.metrics().completed);
    var started = false;
    var released = false;
    while (ring.pop()) |event| {
        if (std.mem.eql(u8, event.kind, "resource_graph.started")) started = true;
        if (std.mem.eql(u8, event.kind, "resource_graph.release")) released = true;
    }
    try std.testing.expect(started and released);
}
