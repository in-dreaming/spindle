const std = @import("std");
const SpinMutex = @import("../sync/spin_mutex.zig").SpinMutex;
const Event = @import("../sync/event.zig").Event;
const executor = @import("../executor/root.zig");
const observability = @import("../observability/root.zig");
const node = @import("node.zig");
const graph_mod = @import("compiled_graph.zig");

pub const ExecutionResult = error{ GraphFailed, Cancelled };
pub const Snapshot = struct { states: []const node.LocalTaskState, completed: usize, total: usize };

const RuntimeNode = struct {
    task: executor.Task,
    context: node.TaskContext,
    owner: *State,
};
const State = struct {
    allocator: std.mem.Allocator,
    graph: *const graph_mod.CompiledLocalTaskGraph,
    runtime: []RuntimeNode,
    states: []node.LocalTaskState,
    remaining: []usize,
    // Completion holds this lock only for state transitions; a spinning lock avoids a
    // park/wake race while several prerequisites complete the same fan-in node.
    mutex: SpinMutex = .{},
    done: Event = Event.init(.manual, false),
    cancellation: executor.CancellationSource = .{},
    terminal_count: usize = 0,
    failed: bool = false,
    externally_cancelled: bool = false,
    trace: ?observability.EventSink,

    fn emit(self: *State, kind: []const u8, index: usize) void {
        const now = std.Io.Clock.Timestamp.now(std.Options.debug_io, .awake).raw.nanoseconds;
        observability.EventSink.emit(self.trace, .{ .monotonic_ns = @intCast(@max(now, 0)), .kind = kind, .value = @intCast(index + 1) });
    }
    fn complete(self: *State, index: usize, task_state: executor.TaskState) void {
        var ready = std.ArrayListUnmanaged(usize).empty;
        defer ready.deinit(self.allocator);
        self.mutex.lock();
        if (self.states[index] == .completed or self.states[index] == .failed or self.states[index] == .cancelled) {
            self.mutex.unlock();
            return;
        }
        const successful = task_state == .completed;
        self.states[index] = if (successful) .completed else if (task_state == .failed) .failed else .cancelled;
        self.terminal_count += 1;
        self.emit(if (successful) "task_graph.finished" else "task_graph.cancelled", index);
        if (!successful and task_state == .failed) {
            self.failed = true;
            self.cancellation.cancel();
        }
        if (successful and !self.cancellation.token().isCancelled()) {
            const n = self.graph.nodes[index];
            for (self.graph.dependents[n.dependent_start .. n.dependent_start + n.dependent_len]) |dependent| {
                self.remaining[dependent] -= 1;
                self.emit("task_graph.dependency_released", dependent);
                if (self.remaining[dependent] == 0 and self.states[dependent] == .pending) {
                    self.states[dependent] = .queued;
                    self.emit("task_graph.ready", dependent);
                    ready.append(self.allocator, dependent) catch {
                        self.failed = true;
                        self.cancellation.cancel();
                    };
                }
            }
        }
        const cancelling = self.cancellation.token().isCancelled();
        if (cancelling) self.cancelUnstartedLocked();
        if (self.terminal_count == self.states.len) self.done.set();
        self.mutex.unlock();
        self.cancelQueuedTasks();
        for (ready.items) |next| self.submit(next);
    }
    fn cancelUnstartedLocked(self: *State) void {
        for (self.states, 0..) |*status, i| switch (status.*) {
            .pending, .queued => {
                status.* = .cancelled;
                self.terminal_count += 1;
                self.emit("task_graph.cancelled", i);
            },
            else => {},
        };
    }
    fn cancelQueuedTasks(self: *State) void {
        for (self.states, 0..) |status, i| {
            if (status == .cancelled) _ = self.runtime[i].task.cancel();
        }
    }
    fn submit(self: *State, index: usize) void {
        self.emit("task_graph.enqueued", index);
        self.graph.nodes[index].target.submit(&self.runtime[index].task, .{}) catch {
            self.runtime[index].task.state.store(.failed, .release);
            self.runtime[index].task.done.set();
            self.complete(index, .failed);
        };
    }
    fn run(task: *executor.Task) void {
        const runtime: *RuntimeNode = @ptrCast(@alignCast(task.context.?));
        const state = runtime.owner;
        const index: usize = @as(usize, @intCast(@intFromPtr(runtime) - @intFromPtr(state.runtime.ptr))) / @sizeOf(RuntimeNode);
        state.mutex.lock();
        if (state.states[index] == .cancelled) {
            state.mutex.unlock();
            return;
        }
        state.states[index] = .running;
        state.emit("task_graph.started", index);
        runtime.context.user_context = state.graph.nodes[index].context;
        state.mutex.unlock();
        state.graph.nodes[index].run(&runtime.context);
        if (runtime.context.failed) task.fail();
    }
    fn onTaskComplete(task: *executor.Task) void {
        const runtime: *RuntimeNode = @ptrCast(@alignCast(task.context.?));
        const state = runtime.owner;
        const index: usize = @as(usize, @intCast(@intFromPtr(runtime) - @intFromPtr(state.runtime.ptr))) / @sizeOf(RuntimeNode);
        state.complete(index, task.status());
    }
};

/// Owns one graph run. Call `wait` before `deinit`; `deinit` waits defensively.
pub const GraphExecutionHandle = struct {
    state: *State,
    pub fn wait(self: *GraphExecutionHandle) ExecutionResult!void {
        self.state.done.wait(null, .{}) catch unreachable;
        if (self.state.failed) return error.GraphFailed;
        if (self.state.externally_cancelled) return error.Cancelled;
    }
    pub fn cancel(self: *GraphExecutionHandle) void {
        self.state.mutex.lock();
        self.state.externally_cancelled = true;
        self.state.cancellation.cancel();
        self.state.cancelUnstartedLocked();
        if (self.state.terminal_count == self.state.states.len) self.state.done.set();
        self.state.mutex.unlock();
        self.state.cancelQueuedTasks();
    }
    pub fn snapshot(self: *GraphExecutionHandle) Snapshot {
        self.state.mutex.lock();
        defer self.state.mutex.unlock();
        return .{ .states = self.state.states, .completed = self.state.terminal_count, .total = self.state.states.len };
    }
    pub fn deinit(self: *GraphExecutionHandle) void {
        self.state.done.wait(null, .{}) catch {};
        for (self.state.runtime) |*runtime| {
            if (runtime.task.status() != .created) {
                runtime.task.wait() catch {};
                runtime.task.waitQueueReleased() catch {};
            }
        }
        self.state.allocator.free(self.state.runtime);
        self.state.allocator.free(self.state.states);
        self.state.allocator.free(self.state.remaining);
        self.state.allocator.destroy(self.state);
        self.* = undefined;
    }
};

pub fn start(allocator: std.mem.Allocator, graph: *const graph_mod.CompiledLocalTaskGraph, trace: ?observability.EventSink) !GraphExecutionHandle {
    const state = try allocator.create(State);
    errdefer allocator.destroy(state);
    const runtime = try allocator.alloc(RuntimeNode, graph.nodes.len);
    errdefer allocator.free(runtime);
    const states = try allocator.alloc(node.LocalTaskState, graph.nodes.len);
    errdefer allocator.free(states);
    const remaining = try allocator.alloc(usize, graph.nodes.len);
    errdefer allocator.free(remaining);
    state.* = .{ .allocator = allocator, .graph = graph, .runtime = runtime, .states = states, .remaining = remaining, .trace = trace };
    for (graph.nodes, 0..) |n, i| {
        states[i] = .pending;
        remaining[i] = n.dependency_len;
        runtime[i] = .{ .task = executor.Task.init(State.run, &runtime[i]), .context = .{ .user_context = n.context, .cancellation = state.cancellation.token() }, .owner = state };
        runtime[i].task.complete_fn = State.onTaskComplete;
    }
    if (graph.nodes.len == 0) {
        state.done.set();
        return .{ .state = state };
    }
    for (graph.nodes, 0..) |n, i| if (n.dependency_len == 0) {
        states[i] = .queued;
        state.emit("task_graph.ready", i);
        state.submit(i);
    };
    return .{ .state = state };
}
