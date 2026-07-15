const std = @import("std");
const query = @import("query.zig");
const command = @import("command_buffer.zig");

pub const SystemId = u32;
pub const ResourceId = u64;
pub const Phase = enum(u8) { startup, pre_update, update, post_update, render };
pub const Target = enum(u8) { compute, main, render };

/// The callback is invoked once per owned chunk range. A null view denotes a singleton-only system.
pub const RunFn = *const fn (*SystemContext, ?*query.ChunkView) anyerror!void;

/// Static access declaration used by the schedule compiler. All slices are caller-owned and must outlive registration.
pub const SystemDesc = struct {
    id: SystemId,
    name: []const u8,
    phase: Phase = .update,
    target: Target = .compute,
    query: query.Query = .{},
    component_reads: []const u64 = &.{},
    component_writes: []const u64 = &.{},
    resource_reads: []const ResourceId = &.{},
    resource_writes: []const ResourceId = &.{},
    before: []const SystemId = &.{},
    after: []const SystemId = &.{},
    grain: usize = 1,
    run_fn: RunFn,
};

/// Per-job capability passed to systems. Structural changes must be recorded in `commands`.
pub const SystemContext = struct {
    dt: f32,
    commands: *command.CommandBuffer,
    last_run_tick: u32,
    resources: *ResourceRegistry,
    desc: *const SystemDesc,

    /// Returns a singleton only when it was declared as read or write access by this system.
    pub fn resource(self: *SystemContext, id: ResourceId, comptime T: type) error{ UndeclaredResource, MissingResource }!*T {
        if (!containsResource(self.desc.resource_reads, id) and !containsResource(self.desc.resource_writes, id)) return error.UndeclaredResource;
        const value = self.resources.get(id) orelse return error.MissingResource;
        return @ptrCast(@alignCast(value));
    }
};

/// World-owned singleton registry. Registration is forbidden after scheduling starts.
pub const ResourceRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(ResourceId, *anyopaque) = .empty,
    pub fn init(allocator: std.mem.Allocator) ResourceRegistry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *ResourceRegistry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *ResourceRegistry, id: ResourceId, value: *anyopaque) !void {
        if (self.entries.contains(id)) return error.DuplicateResource;
        try self.entries.put(self.allocator, id, value);
    }
    pub fn get(self: *ResourceRegistry, id: ResourceId) ?*anyopaque {
        return self.entries.get(id);
    }
};

pub const Registered = struct { desc: SystemDesc, last_run_tick: u32 = 0 };
pub const Registry = struct {
    allocator: std.mem.Allocator,
    systems: std.ArrayListUnmanaged(Registered) = .empty,
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        self.systems.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *Registry, desc: SystemDesc) !void {
        if (desc.name.len == 0 or desc.grain == 0) return error.InvalidSystem;
        for (self.systems.items) |item| if (item.desc.id == desc.id) return error.DuplicateSystem;
        try self.systems.append(self.allocator, .{ .desc = desc });
    }
    pub fn find(self: *Registry, id: SystemId) ?*Registered {
        for (self.systems.items) |*item| if (item.desc.id == id) return item;
        return null;
    }
};

pub const Batch = struct { systems: []SystemId };
pub const CompiledPhase = struct { phase: Phase, batches: []Batch };
/// Immutable schedule ownership. It remains valid until deinit or a configuration invalidation.
pub const CompiledSchedule = struct {
    allocator: std.mem.Allocator,
    phases: []CompiledPhase,
    pub fn deinit(self: *CompiledSchedule) void {
        for (self.phases) |phase| {
            for (phase.batches) |batch| self.allocator.free(batch.systems);
            self.allocator.free(phase.batches);
        }
        self.allocator.free(self.phases);
        self.* = undefined;
    }
};
fn containsResource(values: []const ResourceId, id: ResourceId) bool {
    for (values) |value| if (value == id) return true;
    return false;
}
