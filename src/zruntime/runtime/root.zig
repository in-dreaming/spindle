const std = @import("std");
const build_options = @import("build_options");
const core = @import("../core/root.zig");
const executor = @import("../executor/root.zig");
const io_adapter = @import("../io_adapter/root.zig");
const observability = @import("../observability/root.zig");
const platform = @import("../platform/root.zig");
const workflow = if (build_options.workflow_sqlite) @import("../workflow/root.zig") else struct {};

pub const Fault = enum { none, clock, compute, blocking, pump, observability, workflow };

pub const Features = struct {
    pub const task_graph = build_options.task_graph;
    pub const ecs = build_options.ecs;
    pub const resource_graph = build_options.resource_graph;
    pub const workflow = build_options.workflow;
    pub const workflow_sqlite = build_options.workflow_sqlite;
    pub const workflow_archive = build_options.workflow_archive;
    pub const workflow_archive_http = build_options.workflow_archive_http;
};

const WorkflowConfig = struct {
    database_path: []const u8,
    tenant: []const u8,
    namespace: []const u8,
    definitions: []const workflow.definition.Definition,
    activities: []const workflow.activity.Registration,
    /// The callback context remains borrowed from the caller for the Runtime lifetime.
    transport: workflow.outbox.Transport,
    workflow_workers: usize = 1,
    activity_workers: usize = 1,
    timer_workers: usize = 1,
    publisher_workers: usize = 1,
    command_capacity: usize = 64,
};

const BaseConfig = struct {
    io: std.Io,
    compute_workers: usize = 1,
    blocking_workers: usize = 1,
    queue_capacity: usize = 64,
    observability_capacity: usize = 128,
    fault: Fault = .none,
};
pub const Config = if (build_options.workflow_sqlite) struct {
    io: std.Io,
    compute_workers: usize = 1,
    blocking_workers: usize = 1,
    queue_capacity: usize = 64,
    observability_capacity: usize = 128,
    workflow: ?WorkflowConfig = null,
    fault: Fault = .none,
} else BaseConfig;

pub const ShutdownStage = enum { workflow, pump, detached, blocking, compute };
pub const ShutdownReport = struct {
    completed: bool,
    timed_out_stage: ?ShutdownStage = null,
    failed_stage: ?ShutdownStage = null,
    outstanding_workflow_workers: usize = 0,
    outstanding_executor_workers: usize = 0,
    outstanding_pump_work: usize = 0,
    outstanding_detached: usize,
    dropped_events: u64,
};

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

pub const ReplayBundle = struct {
    format_version: u32 = 1,
    modules: []const []const u8 = InspectorProtocol.enabledModules(),
};

const WorkflowOwned = if (build_options.workflow_sqlite) struct {
    allocator: std.mem.Allocator,
    store: workflow.sqlite.Store,
    definitions: workflow.definition.Registry,
    activities: workflow.activity.Registry,
    tenant: []u8,
    namespace: []u8,
    owned_definition_names: std.ArrayListUnmanaged([]u8) = .empty,
    owned_activity_names: std.ArrayListUnmanaged([]u8) = .empty,
    owned_activity_ownership: std.ArrayListUnmanaged([]u8) = .empty,
    owned_non_retryable: std.ArrayListUnmanaged([]u32) = .empty,
    subsystem: workflow.sqlite_runtime.WorkflowSubsystem,

    fn init(allocator: std.mem.Allocator, config: WorkflowConfig, clock: core.Clock, compute: *executor.FixedPool, blocking: *executor.BlockingExecutor) !*@This() {
        const self = try allocator.create(@This());
        errdefer allocator.destroy(self);
        {
            const tenant = try allocator.dupe(u8, config.tenant);
            errdefer allocator.free(tenant);
            const namespace = try allocator.dupe(u8, config.namespace);
            errdefer allocator.free(namespace);
            var store = try workflow.sqlite.Store.init(allocator, config.database_path, clock);
            errdefer store.deinit();
            var definitions = workflow.definition.Registry.init(allocator);
            errdefer definitions.deinit();
            var activities = workflow.activity.Registry.init(allocator);
            errdefer activities.deinit();
            self.* = undefined;
            self.allocator = allocator;
            self.store = store;
            self.definitions = definitions;
            self.activities = activities;
            self.tenant = tenant;
            self.namespace = namespace;
            self.owned_definition_names = .empty;
            self.owned_activity_names = .empty;
            self.owned_activity_ownership = .empty;
            self.owned_non_retryable = .empty;
        }
        errdefer self.deinitMetadata();
        for (config.definitions) |definition| {
            const name = try allocator.dupe(u8, definition.stable_name);
            try self.owned_definition_names.append(allocator, name);
            var copied = definition;
            copied.stable_name = name;
            try self.definitions.register(copied);
        }
        self.definitions.freeze();
        for (config.activities) |registration| {
            const name = try allocator.dupe(u8, registration.stable_name);
            try self.owned_activity_names.append(allocator, name);
            const ownership = try allocator.dupe(u8, registration.ownership);
            try self.owned_activity_ownership.append(allocator, ownership);
            const non_retryable = try allocator.dupe(u32, registration.retry_policy.non_retryable);
            try self.owned_non_retryable.append(allocator, non_retryable);
            var copied = registration;
            copied.stable_name = name;
            copied.ownership = ownership;
            copied.retry_policy.non_retryable = non_retryable;
            try self.activities.register(copied);
        }
        self.activities.freeze();
        self.subsystem = workflow.sqlite_runtime.WorkflowSubsystem.initConfigured(
            allocator,
            .{ .allocator = allocator, .store = &self.store, .registry = &self.definitions, .tenant = self.tenant, .namespace = self.namespace, .command_capacity = config.command_capacity },
            .{ .allocator = allocator, .store = &self.store, .registry = &self.activities, .tenant = self.tenant, .namespace = self.namespace, .compute = compute.executor(), .blocking = blocking.executor() },
            .{ .allocator = allocator, .store = &self.store, .tenant = self.tenant, .namespace = self.namespace },
            .{ .allocator = allocator, .store = &self.store, .tenant = self.tenant, .namespace = self.namespace, .transport = config.transport },
            .{ config.workflow_workers, config.activity_workers, config.timer_workers, config.publisher_workers },
        );
        errdefer self.subsystem.deinit();
        try self.subsystem.start();
        return self;
    }
    fn deinitMetadata(self: *@This()) void {
        for (self.owned_definition_names.items) |value| self.allocator.free(value);
        for (self.owned_activity_names.items) |value| self.allocator.free(value);
        for (self.owned_activity_ownership.items) |value| self.allocator.free(value);
        for (self.owned_non_retryable.items) |value| self.allocator.free(value);
        self.owned_definition_names.deinit(self.allocator);
        self.owned_activity_names.deinit(self.allocator);
        self.owned_activity_ownership.deinit(self.allocator);
        self.owned_non_retryable.deinit(self.allocator);
        self.activities.deinit();
        self.definitions.deinit();
        self.store.deinit();
        self.allocator.free(self.namespace);
        self.allocator.free(self.tenant);
    }
    fn deinit(self: *@This()) void {
        self.subsystem.deinit();
        self.deinitMetadata();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
} else struct {};

const State = struct {
    allocator: std.mem.Allocator,
    clock_source: core.clock.SystemClock,
    compute: executor.FixedPool,
    blocking: executor.BlockingExecutor,
    pump: executor.PumpExecutor,
    io: io_adapter.IoRuntime,
    events: []observability.event.Event,
    event_ring: observability.event.RingSink,
    detached: executor.DetachedTracker,
    workflow: if (build_options.workflow_sqlite) ?*WorkflowOwned else void = if (build_options.workflow_sqlite) null else {},
    stopped: bool = false,
};

/// Address-stable aggregate owner for execution, I/O, observability, and optional SQLite Workflow workers.
pub const Runtime = struct {
    state: *State,

    pub fn init(allocator: std.mem.Allocator, config: Config) !Runtime {
        if (config.fault == .clock) return error.InjectedFailure;
        const clock_source = try core.clock.SystemClock.init();
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
        const state = try allocator.create(State);
        errdefer allocator.destroy(state);
        state.* = .{
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
        if (build_options.workflow_sqlite) if (config.workflow) |workflow_config| {
            if (config.fault == .workflow) return error.InjectedFailure;
            state.workflow = try WorkflowOwned.init(allocator, workflow_config, state.clock_source.clock(), &state.compute, &state.blocking);
        };
        return .{ .state = state };
    }

    pub fn clock(self: *Runtime) core.clock.Clock {
        return self.state.clock_source.clock();
    }
    pub fn computeExecutor(self: *Runtime) executor.Executor {
        return self.state.compute.executor();
    }
    pub fn blockingExecutor(self: *Runtime) executor.Executor {
        return self.state.blocking.executor();
    }
    pub fn pumpExecutor(self: *Runtime) executor.Executor {
        return self.state.pump.executor();
    }
    pub fn eventSink(self: *Runtime) observability.EventSink {
        return self.state.event_ring.sink();
    }
    pub fn detachedTracker(self: *Runtime) *executor.DetachedTracker {
        return &self.state.detached;
    }

    pub fn shutdown(self: *Runtime, deadline_monotonic_ns: ?u64) ShutdownReport {
        const state = self.state;
        if (state.stopped) return self.shutdownReport(true, null, null);
        const now = self.clock().monotonicNow();
        const expired = if (deadline_monotonic_ns) |value| now >= value else false;
        const deadline = if (deadline_monotonic_ns) |value| platform.park.deadlineAfter(if (value > now) value - now else 0) else null;
        if (build_options.workflow_sqlite) if (state.workflow) |owned| owned.subsystem.requestStop();
        state.detached.requestStop();
        state.blocking.requestStop(.cancel_pending);
        state.compute.requestStop(.cancel_pending);
        state.pump.shutdown(if (deadline_monotonic_ns == null) .drain else .cancel_pending);
        if (expired) return self.shutdownReport(false, if (build_options.workflow_sqlite and state.workflow != null) .workflow else .pump, null);
        if (build_options.workflow_sqlite) if (state.workflow) |owned| owned.subsystem.wait(deadline) catch |err| return switch (err) {
            error.Timeout => self.shutdownReport(false, .workflow, null),
            else => self.shutdownReport(false, null, .workflow),
        };
        if (platform.park.expired(deadline)) return self.shutdownReport(false, .pump, null);
        state.detached.wait(deadline) catch return self.shutdownReport(false, .detached, null);
        state.blocking.wait(deadline) catch return self.shutdownReport(false, .blocking, null);
        state.compute.wait(deadline) catch return self.shutdownReport(false, .compute, null);
        state.stopped = true;
        return self.shutdownReport(true, null, null);
    }

    fn shutdownReport(self: *Runtime, completed: bool, timeout_stage: ?ShutdownStage, failed_stage: ?ShutdownStage) ShutdownReport {
        const state = self.state;
        return .{
            .completed = completed,
            .timed_out_stage = timeout_stage,
            .failed_stage = failed_stage,
            .outstanding_workflow_workers = if (build_options.workflow_sqlite) if (state.workflow) |owned| owned.subsystem.outstanding() else 0 else 0,
            .outstanding_executor_workers = state.blocking.outstandingWorkers() + state.compute.outstandingWorkers(),
            .outstanding_pump_work = state.pump.outstanding(),
            .outstanding_detached = state.detached.outstanding(),
            .dropped_events = state.event_ring.droppedCount(),
        };
    }

    pub fn deinit(self: *Runtime) void {
        const state = self.state;
        _ = self.shutdown(null);
        if (build_options.workflow_sqlite) if (state.workflow) |owned| owned.deinit();
        state.detached.deinit();
        state.pump.deinit();
        state.blocking.deinit();
        state.compute.deinit();
        state.allocator.free(state.events);
        const allocator = state.allocator;
        allocator.destroy(state);
        self.* = undefined;
    }
};
