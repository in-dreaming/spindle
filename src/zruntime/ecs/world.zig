const std = @import("std");
const entity = @import("entity.zig");
const registry = @import("component_registry.zig");
const signature = @import("signature.zig");
const archetype = @import("archetype.zig");

/// Single-threaded archetype ECS storage. Returned component borrows are invalidated by any structural change.
pub const World = struct {
    allocator: std.mem.Allocator,
    registry: registry.ComponentRegistry,
    entities: entity.EntityStore,
    archetypes: std.ArrayListUnmanaged(archetype.Archetype) = .empty,
    chunk_bytes: usize,
    archetype_version: u64 = 0,
    change_tick: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, options: struct { chunk_bytes: usize = 2048 }) !World {
        var result: World = .{ .allocator = allocator, .registry = registry.ComponentRegistry.init(allocator), .entities = entity.EntityStore.init(allocator), .chunk_bytes = @max(options.chunk_bytes, 2048) };
        errdefer result.deinit();
        const empty = signature.Signature.init(allocator);
        try result.archetypes.append(allocator, archetype.Archetype.init(allocator, empty));
        return result;
    }
    pub fn deinit(self: *World) void {
        for (self.archetypes.items) |*item| item.deinit();
        self.archetypes.deinit(self.allocator);
        self.entities.deinit();
        self.registry.deinit();
        self.* = undefined;
    }
    /// Registers a bytewise-copyable component under an explicit stable name. Registration closes on first create.
    pub fn registerComponent(self: *World, comptime T: type, name: []const u8) !registry.ComponentTypeId {
        return self.registry.registerType(T, name, 1, .{});
    }
    pub fn freezeRegistry(self: *World) void {
        self.registry.freeze();
    }
    pub fn componentId(_: *const World, name: []const u8) registry.ComponentTypeId {
        return registry.ComponentRegistry.idFor(name);
    }
    /// Allocates an entity in the empty archetype.
    pub fn create(self: *World) !entity.Entity {
        self.registry.freeze();
        const value = try self.entities.create();
        errdefer {
            self.entities.slots.items[value.index].location = null;
            self.entities.free_head = value.index;
        }
        const row = try self.archetypes.items[0].allocateRow(&.{}, self.chunk_bytes);
        self.archetypes.items[0].chunks.items[row.chunk_index].entities()[row.row] = value;
        self.entities.setLocation(value, .{ .archetype = 0, .chunk = row.chunk_index, .row = row.row });
        return value;
    }
    pub fn isAlive(self: *const World, value: entity.Entity) bool {
        return self.entities.valid(value);
    }
    pub fn has(self: *const World, value: entity.Entity, id: registry.ComponentTypeId) bool {
        const location = self.entities.location(value) orelse return false;
        return self.archetypes.items[location.archetype].signature.contains(id);
    }
    /// Adds a component and migrates the entity to a new archetype. On allocation or lifecycle failure the old entity remains usable.
    pub fn add(self: *World, value: entity.Entity, id: registry.ComponentTypeId, component: anytype) !void {
        if (self.has(value, id)) return error.AlreadyHasComponent;
        const meta = self.registry.find(id) orelse return error.UnknownComponent;
        if (@sizeOf(@TypeOf(component)) != meta.size) return error.ComponentSizeMismatch;
        try self.migrate(value, id, true, &component);
    }
    /// Removes a component, retaining every other component value.
    pub fn remove(self: *World, value: entity.Entity, id: registry.ComponentTypeId) !void {
        if (!self.has(value, id)) return error.MissingComponent;
        try self.migrate(value, id, false, null);
    }
    /// Replaces an existing value and records the column change tick.
    pub fn set(self: *World, value: entity.Entity, id: registry.ComponentTypeId, component: anytype) !void {
        const ptr = try self.getMut(value, id, @TypeOf(component));
        ptr.* = component;
    }
    pub fn get(self: *const World, value: entity.Entity, id: registry.ComponentTypeId, comptime T: type) !*const T {
        const location = self.entities.location(value) orelse return error.StaleEntity;
        const raw = self.archetypes.items[location.archetype].chunks.items[location.chunk].valueConstPtr(id, location.row) orelse return error.MissingComponent;
        return @ptrCast(@alignCast(raw));
    }
    /// Returns a mutable borrow valid until the next structural change and marks its column changed.
    pub fn getMut(self: *World, value: entity.Entity, id: registry.ComponentTypeId, comptime T: type) !*T {
        const location = self.entities.location(value) orelse return error.StaleEntity;
        var chunk = &self.archetypes.items[location.archetype].chunks.items[location.chunk];
        const raw = chunk.valuePtr(id, location.row) orelse return error.MissingComponent;
        chunk.markChanged(id, self.change_tick);
        return @ptrCast(@alignCast(raw));
    }
    /// Destroys an entity and invokes component destruction exactly once.
    pub fn destroy(self: *World, value: entity.Entity) !void {
        const location = self.entities.location(value) orelse return error.StaleEntity;
        const arch = &self.archetypes.items[location.archetype];
        for (arch.signature.ids.items) |id| {
            const meta = self.registry.find(id).?;
            if (meta.size != 0) meta.ops.deinit(arch.chunks.items[location.chunk].valuePtr(id, location.row).?);
        }
        self.swapRemove(location);
        try self.entities.destroy(value);
    }
    fn metasFor(self: *const World, sig: *const signature.Signature, allocator: std.mem.Allocator) ![]registry.ComponentMeta {
        const values = try allocator.alloc(registry.ComponentMeta, sig.ids.items.len);
        errdefer allocator.free(values);
        for (sig.ids.items, 0..) |id, i| values[i] = self.registry.find(id) orelse return error.UnknownComponent;
        return values;
    }
    /// Consumes `sig`, leaving it empty in every return path.
    fn findOrCreateArchetype(self: *World, sig: *signature.Signature) !usize {
        for (self.archetypes.items, 0..) |*item, i| if (item.signature.eql(sig)) {
            sig.deinit();
            sig.* = signature.Signature.init(self.allocator);
            return i;
        };
        try self.archetypes.append(self.allocator, archetype.Archetype.init(self.allocator, sig.*));
        sig.* = signature.Signature.init(self.allocator);
        self.archetype_version +%= 1;
        return self.archetypes.items.len - 1;
    }
    fn migrate(self: *World, value: entity.Entity, changing_id: registry.ComponentTypeId, adding: bool, new_value: ?*const anyopaque) !void {
        const old_location = self.entities.location(value) orelse return error.StaleEntity;
        var target_sig = try self.archetypes.items[old_location.archetype].signature.clone(self.allocator);
        errdefer target_sig.deinit();
        if (adding) _ = try target_sig.add(changing_id) else _ = target_sig.remove(changing_id);
        const target_index = try self.findOrCreateArchetype(&target_sig);
        if (adding) {
            try self.archetypes.items[old_location.archetype].add_edges.put(self.allocator, changing_id, target_index);
        } else {
            try self.archetypes.items[old_location.archetype].remove_edges.put(self.allocator, changing_id, target_index);
        }
        const metas = try self.metasFor(&self.archetypes.items[target_index].signature, self.allocator);
        defer self.allocator.free(metas);
        const destination = try self.archetypes.items[target_index].allocateRow(metas, self.chunk_bytes);
        var initialized: usize = 0;
        errdefer {
            const target_chunk = &self.archetypes.items[target_index].chunks.items[destination.chunk_index];
            for (self.archetypes.items[target_index].signature.ids.items[0..initialized]) |id| {
                const meta = self.registry.find(id).?;
                if (meta.size != 0) meta.ops.deinit(target_chunk.valuePtr(id, destination.row).?);
            }
            target_chunk.count -= 1;
        }
        const target_chunk = &self.archetypes.items[target_index].chunks.items[destination.chunk_index];
        target_chunk.entities()[destination.row] = value;
        for (self.archetypes.items[target_index].signature.ids.items) |id| {
            const meta = self.registry.find(id).?;
            if (id == changing_id and adding) {
                if (meta.size != 0) @memcpy(@as([*]u8, @ptrCast(target_chunk.valuePtr(id, destination.row).?))[0..meta.size], @as([*]const u8, @ptrCast(new_value.?))[0..meta.size]);
            } else if (meta.size != 0) {
                const source = self.archetypes.items[old_location.archetype].chunks.items[old_location.chunk].valueConstPtr(id, old_location.row).?;
                try meta.ops.clone(target_chunk.valuePtr(id, destination.row).?, source);
            }
            initialized += 1;
        }
        const old_arch = &self.archetypes.items[old_location.archetype];
        for (old_arch.signature.ids.items) |id| {
            const meta = self.registry.find(id).?;
            if (meta.size != 0) meta.ops.deinit(old_arch.chunks.items[old_location.chunk].valuePtr(id, old_location.row).?);
        }
        self.swapRemove(old_location);
        self.entities.setLocation(value, .{ .archetype = target_index, .chunk = destination.chunk_index, .row = destination.row });
    }
    fn swapRemove(self: *World, location: entity.EntityLocation) void {
        var chunk = &self.archetypes.items[location.archetype].chunks.items[location.chunk];
        const last = chunk.count - 1;
        if (location.row != last) {
            const moved = chunk.entities()[last];
            chunk.entities()[location.row] = moved;
            for (chunk.columns.items) |column| @memcpy(chunk.storage[column.offset + location.row * column.stride ..][0..column.stride], chunk.storage[column.offset + last * column.stride ..][0..column.stride]);
            self.entities.setLocation(moved, .{ .archetype = location.archetype, .chunk = location.chunk, .row = location.row });
        }
        chunk.count -= 1;
    }
};

const Position = struct { x: i32, y: i32 };
const Velocity = struct { x: i32, y: i32 };
const Lifecycle = struct {
    value: u32,
    var clones: std.atomic.Value(u32) = .init(0);
    var deinits: std.atomic.Value(u32) = .init(0);
    fn clone(destination: *anyopaque, source: *const anyopaque) !void {
        const dst: *Lifecycle = @ptrCast(@alignCast(destination));
        const src: *const Lifecycle = @ptrCast(@alignCast(source));
        dst.* = src.*;
        _ = clones.fetchAdd(1, .monotonic);
    }
    fn deinit(_: *anyopaque) void {
        _ = deinits.fetchAdd(1, .monotonic);
    }
};

test "world preserves values across archetype migrations and rejects stale entities" {
    var world = try World.init(std.testing.allocator, .{ .chunk_bytes = 2048 });
    defer world.deinit();
    const position = try world.registerComponent(Position, "test.ecs.position");
    const velocity = try world.registerComponent(Velocity, "test.ecs.velocity");
    const tag = try world.registerComponent(void, "test.ecs.tag");
    const first = try world.create();
    try world.add(first, position, Position{ .x = 3, .y = 4 });
    try world.add(first, velocity, Velocity{ .x = 7, .y = 9 });
    try world.add(first, tag, {});
    try std.testing.expectEqual(@as(i32, 3), (try world.get(first, position, Position)).x);
    try std.testing.expectEqual(@as(i32, 9), (try world.get(first, velocity, Velocity)).y);
    try world.remove(first, velocity);
    try std.testing.expect(!world.has(first, velocity));
    try std.testing.expectEqual(@as(i32, 4), (try world.get(first, position, Position)).y);
    try world.destroy(first);
    try std.testing.expectError(error.StaleEntity, world.get(first, position, Position));
    const replacement = try world.create();
    try std.testing.expectEqual(first.index, replacement.index);
    try std.testing.expect(first.generation != replacement.generation);
}

test "world repairs locations after a middle-row swap remove across chunks" {
    var world = try World.init(std.testing.allocator, .{ .chunk_bytes = 2048 });
    defer world.deinit();
    const position = try world.registerComponent(Position, "test.ecs.dense-position");
    var values: [300]entity.Entity = undefined;
    for (&values, 0..) |*slot, i| {
        slot.* = try world.create();
        try world.add(slot.*, position, Position{ .x = @intCast(i), .y = -@as(i32, @intCast(i)) });
    }
    try world.destroy(values[123]);
    try std.testing.expectError(error.StaleEntity, world.get(values[123], position, Position));
    for (values, 0..) |value, i| {
        if (i == 123) continue;
        const found = try world.get(value, position, Position);
        try std.testing.expectEqual(@as(i32, @intCast(i)), found.x);
        try std.testing.expectEqual(-@as(i32, @intCast(i)), found.y);
    }
}

test "world invokes nontrivial lifecycle operations once per migrated source value" {
    Lifecycle.clones.store(0, .monotonic);
    Lifecycle.deinits.store(0, .monotonic);
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();
    const life = registry.ComponentRegistry.idFor("test.ecs.lifecycle");
    try world.registry.register(.{ .id = life, .name = "test.ecs.lifecycle", .size = @sizeOf(Lifecycle), .alignment = @alignOf(Lifecycle), .schema_version = 1, .flags = .{}, .ops = .{ .clone = Lifecycle.clone, .deinit = Lifecycle.deinit } });
    const velocity = try world.registerComponent(Velocity, "test.ecs.lifecycle-velocity");
    const value = try world.create();
    try world.add(value, life, Lifecycle{ .value = 42 });
    try world.add(value, velocity, Velocity{ .x = 1, .y = 2 });
    try world.remove(value, velocity);
    try std.testing.expectEqual(@as(u32, 2), Lifecycle.clones.load(.monotonic));
    try std.testing.expectEqual(@as(u32, 2), Lifecycle.deinits.load(.monotonic));
    try world.destroy(value);
    try std.testing.expectEqual(@as(u32, 3), Lifecycle.deinits.load(.monotonic));
}

fn allocationFailureScenario(allocator: std.mem.Allocator) !void {
    var world = try World.init(allocator, .{});
    defer world.deinit();
    const position = try world.registerComponent(Position, "test.ecs.oom-position");
    const velocity = try world.registerComponent(Velocity, "test.ecs.oom-velocity");
    const value = try world.create();
    try world.add(value, position, Position{ .x = 10, .y = 20 });
    try world.add(value, velocity, Velocity{ .x = 30, .y = 40 });
    try world.destroy(value);
}

test "world releases every allocation on create and migration failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureScenario, .{});
}

test "failed create and migration leave the old entity state usable" {
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();
    const position = try world.registerComponent(Position, "test.ecs.oom-state-position");
    const velocity = try world.registerComponent(Velocity, "test.ecs.oom-state-velocity");

    var create_fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    world.entities.allocator = create_fail.allocator();
    try std.testing.expectError(error.OutOfMemory, world.create());
    try std.testing.expectEqual(@as(usize, 0), world.entities.slots.items.len);
    world.entities.allocator = std.testing.allocator;

    const value = try world.create();
    try world.add(value, position, Position{ .x = 7, .y = 11 });
    var migration_fail = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    world.allocator = migration_fail.allocator();
    try std.testing.expectError(error.OutOfMemory, world.add(value, velocity, Velocity{ .x = 1, .y = 2 }));
    try std.testing.expect(world.isAlive(value));
    try std.testing.expect(!world.has(value, velocity));
    const retained = try world.get(value, position, Position);
    try std.testing.expectEqual(@as(i32, 7), retained.x);
    try std.testing.expectEqual(@as(i32, 11), retained.y);
    world.allocator = std.testing.allocator;
}
