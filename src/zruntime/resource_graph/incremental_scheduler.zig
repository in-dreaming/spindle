const std = @import("std");
const executor = @import("../executor/root.zig");
const access_mod = @import("access.zig");
const key_mod = @import("resource_key.zig");
const version_mod = @import("version.zig");

pub const State = enum { pending, queued, running, completed, failed, cancelled };
pub const Route = enum { compute, blocking, pump };
pub const RunFn = *const fn (?*anyopaque) anyerror!void;
pub const VersionResolver = struct {
    context: ?*anyopaque = null,
    resolve: *const fn (?*anyopaque, key_mod.ResourceKey) ?version_mod.ResourceVersion,
};

const OwnedAccess = struct {
    value: access_mod.ResourceAccess,
    name: []u8,
    custom_range: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, source: access_mod.ResourceAccess) !OwnedAccess {
        try source.validate();
        const name = try allocator.dupe(u8, source.key.name);
        errdefer allocator.free(name);
        const custom = switch (source.range) {
            .custom => |bytes| try allocator.dupe(u8, bytes),
            else => null,
        };
        var key = source.key;
        key.name = name;
        if (key.file) |*file| file.path = name;
        var range = source.range;
        if (custom) |bytes| range = .{ .custom = bytes };
        return .{ .value = .{ .key = key, .range = range, .mode = source.mode, .version = source.version }, .name = name, .custom_range = custom };
    }
    fn deinit(self: *OwnedAccess, allocator: std.mem.Allocator) void {
        if (self.custom_range) |bytes| allocator.free(bytes);
        allocator.free(self.name);
    }
};

pub const Submission = struct {
    scheduler: *Scheduler,
    state: State = .pending,
    route: Route,
    run_fn: RunFn,
    context: ?*anyopaque,
    accesses: []OwnedAccess,
    task: executor.Task,
    error_value: ?anyerror = null,

    pub fn status(self: *const Submission) State {
        lock(&self.scheduler.mutex);
        defer self.scheduler.mutex.unlock();
        return self.state;
    }
    pub fn failure(self: *const Submission) ?anyerror {
        lock(&self.scheduler.mutex);
        defer self.scheduler.mutex.unlock();
        return self.error_value;
    }
};

/// Incremental resource scheduler for independently arriving tasks. Accesses
/// are copied at submit time and all conflicting earlier submissions retire
/// before a later callback starts. The owner must release terminal handles.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    executors: [3]executor.Executor,
    resolver: ?VersionResolver,
    entries: std.ArrayListUnmanaged(*Submission) = .empty,
    mutex: std.atomic.Mutex = .unlocked,
    stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator, compute: executor.Executor, blocking: executor.Executor, pump: executor.Executor, resolver: ?VersionResolver) Scheduler {
        return .{ .allocator = allocator, .executors = .{ compute, blocking, pump }, .resolver = resolver };
    }
    pub fn deinit(self: *Scheduler) void {
        self.shutdown();
        inline for (0..3) |index| {
            var drain = DrainContext{ .scheduler = self, .route = @enumFromInt(index) };
            self.executors[index].helpUntil(&drain, routeRetired);
        }
        lock(&self.mutex);
        for (self.entries.items) |entry| self.destroyEntry(entry);
        self.entries.deinit(self.allocator);
        self.mutex.unlock();
    }
    pub fn submit(self: *Scheduler, route: Route, accesses: []const access_mod.ResourceAccess, run_fn: RunFn, context: ?*anyopaque) !*Submission {
        const entry = try self.allocator.create(Submission);
        errdefer self.allocator.destroy(entry);
        const owned = try self.allocator.alloc(OwnedAccess, accesses.len);
        errdefer self.allocator.free(owned);
        var initialized: usize = 0;
        errdefer for (owned[0..initialized]) |*item| item.deinit(self.allocator);
        for (accesses, 0..) |source, index| {
            owned[index] = try OwnedAccess.init(self.allocator, source);
            initialized += 1;
        }
        entry.* = .{ .scheduler = self, .route = route, .run_fn = run_fn, .context = context, .accesses = owned, .task = executor.Task.init(runTask, null) };
        entry.task.context = entry;
        lock(&self.mutex);
        if (self.stopped) {
            self.mutex.unlock();
            return error.Shutdown;
        }
        self.entries.append(self.allocator, entry) catch {
            self.mutex.unlock();
            return error.OutOfMemory;
        };
        self.mutex.unlock();
        self.dispatch();
        return entry;
    }
    pub fn cancel(self: *Scheduler, entry: *Submission) void {
        lock(&self.mutex);
        if (entry.state == .pending or entry.state == .queued) {
            _ = entry.task.cancel();
            entry.state = .cancelled;
        }
        self.mutex.unlock();
        self.dispatch();
    }
    pub fn release(self: *Scheduler, entry: *Submission) !void {
        lock(&self.mutex);
        defer self.mutex.unlock();
        if (!terminal(entry.state) or entry.task.queue_references.load(.acquire) != 0) return error.InvalidState;
        for (self.entries.items, 0..) |candidate, index| if (candidate == entry) {
            _ = self.entries.swapRemove(index);
            self.destroyEntry(entry);
            return;
        };
        return error.InvalidState;
    }
    pub fn shutdown(self: *Scheduler) void {
        lock(&self.mutex);
        self.stopped = true;
        for (self.entries.items) |entry| if (entry.state == .pending or entry.state == .queued) {
            _ = entry.task.cancel();
            entry.state = .cancelled;
        };
        self.mutex.unlock();
    }
    fn dispatch(self: *Scheduler) void {
        while (true) {
            lock(&self.mutex);
            const candidate = self.nextReadyLocked() orelse {
                self.mutex.unlock();
                return;
            };
            candidate.state = .queued;
            self.mutex.unlock();
            self.executors[@intFromEnum(candidate.route)].submit(&candidate.task, .{}) catch |err| {
                lock(&self.mutex);
                candidate.state = .failed;
                candidate.error_value = err;
                self.mutex.unlock();
            };
        }
    }
    fn nextReadyLocked(self: *Scheduler) ?*Submission {
        for (self.entries.items, 0..) |candidate, index| {
            if (candidate.state != .pending) continue;
            var blocked = false;
            for (self.entries.items[0..index]) |earlier| {
                if (terminal(earlier.state)) continue;
                if (conflicts(earlier.accesses, candidate.accesses)) {
                    blocked = true;
                    break;
                }
            }
            if (!blocked) return candidate;
        }
        return null;
    }
    fn runTask(task: *executor.Task) void {
        const entry: *Submission = @ptrCast(@alignCast(task.context.?));
        const self = entry.scheduler;
        lock(&self.mutex);
        if (entry.state == .cancelled) {
            self.mutex.unlock();
            self.dispatch();
            return;
        }
        entry.state = .running;
        self.mutex.unlock();
        const version_error = self.validateVersions(entry.accesses);
        if (version_error) |err| {
            self.complete(entry, .failed, err);
            return;
        }
        entry.run_fn(entry.context) catch |err| {
            self.complete(entry, .failed, err);
            return;
        };
        self.complete(entry, .completed, null);
    }
    fn complete(self: *Scheduler, entry: *Submission, state: State, err: ?anyerror) void {
        lock(&self.mutex);
        if (!terminal(entry.state)) {
            entry.state = state;
            entry.error_value = err;
        }
        self.mutex.unlock();
        self.dispatch();
    }
    fn validateVersions(self: *Scheduler, accesses: []const OwnedAccess) ?anyerror {
        for (accesses) |owned| switch (owned.value.version) {
            .any => {},
            .must_not_exist => if (self.resolver == null or self.resolver.?.resolve(self.resolver.?.context, owned.value.key) != null) return error.VersionMismatch,
            .generation => |expected| {
                const current = if (self.resolver) |resolver| resolver.resolve(resolver.context, owned.value.key) else null;
                if (current == null or current.?.generation != expected) return error.VersionMismatch;
            },
            .exact => |expected| {
                const current = if (self.resolver) |resolver| resolver.resolve(resolver.context, owned.value.key) else null;
                if (current == null or current.?.content_hash == null or current.?.content_hash.? != expected) return error.VersionMismatch;
            },
        };
        return null;
    }
    fn destroyEntry(self: *Scheduler, entry: *Submission) void {
        for (entry.accesses) |*item| item.deinit(self.allocator);
        self.allocator.free(entry.accesses);
        self.allocator.destroy(entry);
    }
};

const DrainContext = struct { scheduler: *Scheduler, route: Route };
fn routeRetired(raw: *anyopaque) bool {
    const context: *DrainContext = @ptrCast(@alignCast(raw));
    lock(&context.scheduler.mutex);
    defer context.scheduler.mutex.unlock();
    for (context.scheduler.entries.items) |entry| {
        if (entry.route == context.route and (!terminal(entry.state) or entry.task.queue_references.load(.acquire) != 0)) return false;
    }
    return true;
}

fn terminal(state: State) bool {
    return state == .completed or state == .failed or state == .cancelled;
}
fn lock(mutex: *std.atomic.Mutex) void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}
fn conflicts(left: []const OwnedAccess, right: []const OwnedAccess) bool {
    for (left) |a| for (right) |b| {
        if (!keysOverlap(a.value.key, b.value.key) or !a.value.range.overlaps(b.value.range)) continue;
        if (a.value.mode != .read or b.value.mode != .read) return true;
    };
    return false;
}
fn keysOverlap(a: key_mod.ResourceKey, b: key_mod.ResourceKey) bool {
    if (a.file) |file_a| if (b.file) |file_b| {
        if (!file_a.eql(file_b)) return false;
        if (a.kind == .file or b.kind == .file) return true;
        return a.page == b.page;
    };
    return a.eql(b);
}

test "incremental scheduler orders writes and overlaps reads" {
    var pump = try executor.PumpExecutor.init(std.testing.allocator, 8);
    defer pump.deinit();
    var scheduler = Scheduler.init(std.testing.allocator, pump.executor(), pump.executor(), pump.executor(), null);
    defer scheduler.deinit();
    const Probe = struct {
        value: *u32,
        add: u32,
        fn run(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.value.* = self.value.* * 10 + self.add;
        }
    };
    const key = key_mod.ResourceKey.named(.custom, .zero, "world");
    const write = [_]access_mod.ResourceAccess{.{ .key = key, .mode = .write }};
    var value: u32 = 0;
    var one = Probe{ .value = &value, .add = 1 };
    var two = Probe{ .value = &value, .add = 2 };
    const first = try scheduler.submit(.pump, &write, Probe.run, &one);
    const second = try scheduler.submit(.pump, &write, Probe.run, &two);
    try std.testing.expectEqual(State.queued, first.status());
    try std.testing.expectEqual(State.pending, second.status());
    _ = pump.drain(8);
    try std.testing.expectEqual(@as(u32, 12), value);
    try scheduler.release(first);
    try scheduler.release(second);
}

test "incremental scheduler validates versions before callback" {
    var immediate = executor.InlineExecutor{};
    const Resolver = struct {
        fn resolve(_: ?*anyopaque, _: key_mod.ResourceKey) ?version_mod.ResourceVersion {
            return .{ .generation = 7, .content_hash = 11 };
        }
    };
    var scheduler = Scheduler.init(std.testing.allocator, immediate.executor(), immediate.executor(), immediate.executor(), .{ .resolve = Resolver.resolve });
    defer scheduler.deinit();
    const Probe = struct {
        calls: *usize,
        fn run(raw: ?*anyopaque) !void {
            @as(*usize, @ptrCast(@alignCast(raw.?))).* += 1;
        }
    };
    var calls: usize = 0;
    const key = key_mod.ResourceKey.named(.custom, .zero, "versioned");
    const accesses = [_]access_mod.ResourceAccess{.{ .key = key, .mode = .read, .version = .{ .generation = 8 } }};
    const submission = try scheduler.submit(.compute, &accesses, Probe.run, &calls);
    try std.testing.expectEqual(State.failed, submission.status());
    try std.testing.expectEqual(@as(usize, 0), calls);
    try std.testing.expect(submission.failure() == error.VersionMismatch);
    try scheduler.release(submission);
}

test "incremental scheduler deinit retires queued intrusive tasks" {
    var pump = try executor.PumpExecutor.init(std.testing.allocator, 2);
    defer pump.deinit();
    var scheduler = Scheduler.init(std.testing.allocator, pump.executor(), pump.executor(), pump.executor(), null);
    const Probe = struct {
        fn run(_: ?*anyopaque) !void {
            return error.TestUnexpectedResult;
        }
    };
    _ = try scheduler.submit(.pump, &.{}, Probe.run, null);
    scheduler.deinit();
    try std.testing.expectEqual(@as(usize, 0), pump.outstanding());
}
