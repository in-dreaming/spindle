const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");
const executor = @import("../executor/root.zig");
const io_adapter = @import("../io_adapter/root.zig");
const observability = @import("../observability/root.zig");

/// Runtime construction failure injection used only by integration tests.
pub const Fault = enum { none, clock, compute, blocking, pump, observability };

/// Compile-time profile values for consumers that need to adapt aggregate APIs.
pub const Features = struct {
    pub const task_graph = build_options.task_graph;
    pub const ecs = build_options.ecs;
    pub const resource_graph = build_options.resource_graph;
    pub const workflow = build_options.workflow;
    pub const workflow_sqlite = build_options.workflow_sqlite;
    pub const workflow_archive = build_options.workflow_archive;
    pub const workflow_archive_http = build_options.workflow_archive_http;
};

/// Runtime resource configuration. The supplied `std.Io` remains owned by the caller.
pub const Config = struct {
    io: std.Io,
    compute_workers: usize = 1,
    blocking_workers: usize = 1,
    queue_capacity: usize = 64,
    observability_capacity: usize = 128,
    fault: Fault = .none,
};

/// Result of a completed shutdown. A deadline is reported without releasing live resources.
pub const ShutdownReport = struct {
    completed: bool,
    outstanding_detached: usize,
    dropped_events: u64,
};

/// Public inventory for inspector and replay clients. It contains no persistence internals.
pub const InspectorProtocol = struct {
    pub const version: u32 = 1;
    pub fn enabledModules() []const []const u8 {
        return comptime modules();
    }
    fn modules() []const []const u8 {
        var values: []const []const u8 = &.{ "core", "executor", "io_adapter", "observability" };
        if (build_options.task_graph) values = values ++ .{"task_graph"};
        if (build_options.ecs) values = values ++ .{"ecs"};
        if (build_options.resource_graph) values = values ++ .{"resource_graph"};
        if (build_options.workflow) values = values ++ .{"workflow"};
        if (build_options.workflow_sqlite) values = values ++ .{"workflow_sqlite"};
        if (build_options.workflow_archive) values = values ++ .{"workflow_archive"};
        if (build_options.workflow_archive_http) values = values ++ .{"workflow_archive_http"};
        return values;
    }
};

/// Stable replay envelope whose module list is limited to the active build profile.
pub const ReplayBundle = struct {
    format_version: u32 = 1,
    modules: []const []const u8 = InspectorProtocol.enabledModules(),
};

/// Owns compute, blocking, pump execution, clock, I/O adapter, detached work, and observability.
/// It starts no upper-module or persistence resource in profiles that omit those features.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    clock_source: core.clock.SystemClock,
    compute: executor.FixedPool,
    blocking: executor.BlockingExecutor,
    pump: executor.PumpExecutor,
    io: io_adapter.IoRuntime,
    events: []observability.event.Event,
    event_ring: observability.event.RingSink,
    detached: executor.DetachedTracker,
    stopped: bool = false,

    /// Initializes each owned resource in dependency order and unwinds in reverse on failure.
    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime {
        if (config.fault == .clock) return error.InjectedFailure;
        var clock_source = try core.clock.SystemClock.init();
        _ = &clock_source;
        if (config.fault == .compute) return error.InjectedFailure;
        var compute = try executor.FixedPool.init(allocator, config.compute_workers, config.queue_capacity);
        errdefer compute.deinit();
        if (config.fault == .blocking) return error.InjectedFailure;
        var blocking = try executor.BlockingExecutor.init(allocator, config.blocking_workers, config.queue_capacity);
        errdefer blocking.deinit();
        if (config.fault == .pump) return error.InjectedFailure;
        var pump = try executor.PumpExecutor.init(allocator, config.queue_capacity);
        errdefer pump.deinit();
        if (config.fault == .observability) return error.InjectedFailure;
        const events = try allocator.alloc(observability.event.Event, config.observability_capacity);
        errdefer allocator.free(events);
        return .{
            .allocator = allocator,
            .clock_source = clock_source,
            .compute = compute,
            .blocking = blocking,
            .pump = pump,
            .io = io_adapter.IoRuntime.init(config.io),
            .events = events,
            .event_ring = observability.event.RingSink.init(events),
            .detached = executor.DetachedTracker.init(allocator),
        };
    }

    pub fn clock(self: *Runtime) core.clock.Clock {
        return self.clock_source.clock();
    }
    pub fn computeExecutor(self: *Runtime) executor.Executor {
        return self.compute.executor();
    }
    pub fn blockingExecutor(self: *Runtime) executor.Executor {
        return self.blocking.executor();
    }
    pub fn pumpExecutor(self: *Runtime) executor.Executor {
        return self.pump.executor();
    }
    pub fn eventSink(self: *Runtime) observability.EventSink {
        return self.event_ring.sink();
    }
    pub fn detachedTracker(self: *Runtime) *executor.DetachedTracker {
        return &self.detached;
    }

    /// Performs the runtime shutdown sequence and joins all owned execution resources before release.
    pub fn shutdown(self: *Runtime, deadline_monotonic_ns: ?u64) ShutdownReport {
        if (self.stopped) return .{ .completed = true, .outstanding_detached = 0, .dropped_events = self.event_ring.droppedCount() };
        if (deadline_monotonic_ns) |deadline| if (self.clock().monotonicNow() >= deadline) {
            return .{ .completed = false, .outstanding_detached = self.detached.allocations.items.len, .dropped_events = self.event_ring.droppedCount() };
        };
        self.pump.shutdown(.drain);
        self.detached.shutdown();
        self.blocking.shutdown(.cancel_pending);
        self.compute.shutdown(.cancel_pending);
        self.stopped = true;
        return .{ .completed = true, .outstanding_detached = self.detached.allocations.items.len, .dropped_events = self.event_ring.droppedCount() };
    }

    pub fn deinit(self: *Runtime) void {
        _ = self.shutdown(null);
        self.detached.deinit();
        self.pump.deinit();
        self.blocking.deinit();
        self.compute.deinit();
        self.allocator.free(self.events);
        self.* = undefined;
    }
};
