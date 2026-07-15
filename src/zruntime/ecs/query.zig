const std = @import("std");
const World = @import("world.zig").World;
const ComponentTypeId = @import("component_registry.zig").ComponentTypeId;
const Chunk = @import("chunk.zig").Chunk;

/// Declares the components a query may inspect or mutate. Write access is both a runtime permission and a scheduler dependency.
pub const Query = struct {
    required: []const ComponentTypeId = &.{},
    excluded: []const ComponentTypeId = &.{},
    optional: []const ComponentTypeId = &.{},
    changed: []const ComponentTypeId = &.{},
    read: []const ComponentTypeId = &.{},
    write: []const ComponentTypeId = &.{},
    since_tick: u32 = 0,
};

pub const ColumnBinding = struct { id: ComponentTypeId, writable: bool };
pub const Error = error{ InvalidQuery, PlanInvalidated, UndeclaredWrite, DuplicateMutableBorrow, MissingColumn };

/// A cached, incrementally refreshed archetype query. It does not own the Query slices.
pub const QueryPlan = struct {
    allocator: std.mem.Allocator,
    query: Query,
    bindings: std.ArrayListUnmanaged(usize) = .empty,
    observed_archetype_version: u64 = 0,
    observed_archetype_count: usize = 0,
    observed_registry_len: usize = 0,
    observed_registry_version: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, world: *const World, query: Query) (std.mem.Allocator.Error || Error)!QueryPlan {
        var result: QueryPlan = .{ .allocator = allocator, .query = query, .observed_registry_len = world.registry.entries.items.len, .observed_registry_version = world.registry.version };
        try result.validate();
        try result.refresh(world);
        return result;
    }
    pub fn deinit(self: *QueryPlan) void {
        self.bindings.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn refresh(self: *QueryPlan, world: *const World) (std.mem.Allocator.Error || Error)!void {
        if (world.registry.entries.items.len != self.observed_registry_len or world.registry.version != self.observed_registry_version) return error.PlanInvalidated;
        if (self.observed_archetype_version == world.archetype_version) return;
        const start = self.observed_archetype_count;
        for (world.archetypes.items[start..], start..) |*arch, i| if (self.matches(arch.signature)) try self.bindings.append(self.allocator, i);
        self.observed_archetype_version = world.archetype_version;
        self.observed_archetype_count = world.archetypes.items.len;
    }
    /// Creates an iterator which yields borrowed chunks. Call ChunkView.deinit before structural mutation.
    pub fn iterator(self: *QueryPlan, world: *World) (std.mem.Allocator.Error || Error)!Iterator {
        try self.refresh(world);
        return .{ .plan = self, .world = world };
    }
    fn validate(self: *const QueryPlan) Error!void {
        for (self.query.write, 0..) |id, i| {
            for (self.query.write[0..i]) |prior| if (prior == id) return error.DuplicateMutableBorrow;
            if (!contains(self.query.required, id) and !contains(self.query.optional, id)) return error.UndeclaredWrite;
        }
        for (self.query.read, 0..) |id, i| {
            for (self.query.read[0..i]) |prior| if (prior == id) return error.InvalidQuery;
            if (contains(self.query.write, id)) return error.InvalidQuery;
        }
    }
    fn matches(self: *const QueryPlan, sig: anytype) bool {
        for (self.query.required) |id| if (!sig.contains(id)) return false;
        for (self.query.excluded) |id| if (sig.contains(id)) return false;
        return true;
    }
    fn changedMatches(self: *const QueryPlan, chunk: *const Chunk) bool {
        if (self.query.changed.len == 0) return true;
        for (self.query.changed) |id| {
            const col = chunk.column(id) orelse continue;
            if (isNewer(col.version, self.query.since_tick)) return true;
        }
        return false;
    }
};

pub const Iterator = struct {
    plan: *QueryPlan,
    world: *World,
    binding_index: usize = 0,
    chunk_index: usize = 0,
    pub fn next(self: *Iterator) ?ChunkView {
        while (self.binding_index < self.plan.bindings.items.len) {
            const arch = &self.world.archetypes.items[self.plan.bindings.items[self.binding_index]];
            if (self.chunk_index >= arch.chunks.items.len) {
                self.binding_index += 1;
                self.chunk_index = 0;
                continue;
            }
            const value = &arch.chunks.items[self.chunk_index];
            self.chunk_index += 1;
            if (value.count == 0 or !self.plan.changedMatches(value)) continue;
            self.world.beginChunkBorrow();
            return .{ .world = self.world, .chunk = value, .query = self.plan.query, .start = 0, .end = value.count };
        }
        return null;
    }
};

/// A live chunk borrow. The caller owns it and must deinit it before a structural World operation.
pub const ChunkView = struct {
    world: *World,
    chunk: *Chunk,
    query: Query,
    start: usize = 0,
    end: usize = 0,
    pub fn deinit(self: *ChunkView) void {
        self.world.endChunkBorrow();
        self.* = undefined;
    }
    pub fn entities(self: *const ChunkView) []const @import("entity.zig").Entity {
        return self.chunk.entities()[self.start..self.end];
    }
    pub fn read(self: *const ChunkView, id: ComponentTypeId, comptime T: type) Error![]const T {
        if (!contains(self.query.required, id) and !contains(self.query.optional, id) and !contains(self.query.read, id)) return error.MissingColumn;
        const col = self.chunk.column(id) orelse return error.MissingColumn;
        return @as([*]const T, @ptrCast(@alignCast(self.chunk.storage.ptr + col.offset)))[self.start..self.end];
    }
    pub fn write(self: *ChunkView, id: ComponentTypeId, comptime T: type) Error![]T {
        if (!contains(self.query.write, id)) return error.UndeclaredWrite;
        const col = self.chunk.column(id) orelse return error.MissingColumn;
        self.chunk.markChanged(id, self.world.change_tick);
        return @as([*]T, @ptrCast(@alignCast(self.chunk.storage.ptr + col.offset)))[self.start..self.end];
    }
};

pub fn isNewer(value: u32, cursor: u32) bool {
    return value != cursor and @as(i32, @bitCast(value -% cursor)) > 0;
}
fn contains(values: []const ComponentTypeId, needle: ComponentTypeId) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}
