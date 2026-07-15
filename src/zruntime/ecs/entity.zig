const std = @import("std");

/// A generational entity handle. A handle is valid only while both index and generation match.
pub const Entity = packed struct { index: u32, generation: u32 };

/// Physical position of an entity in archetype/chunk storage.
pub const EntityLocation = struct { archetype: usize, chunk: usize, row: usize };

pub const EntitySlot = struct { generation: u32 = 1, location: ?EntityLocation = null, next_free: ?u32 = null };

/// Single-threaded generational entity table owned by a World.
pub const EntityStore = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayListUnmanaged(EntitySlot) = .empty,
    free_head: ?u32 = null,

    pub fn init(allocator: std.mem.Allocator) EntityStore {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *EntityStore) void {
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn create(self: *EntityStore) !Entity {
        if (self.free_head) |index| {
            const slot = &self.slots.items[index];
            self.free_head = slot.next_free;
            slot.next_free = null;
            return .{ .index = index, .generation = slot.generation };
        }
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{});
        return .{ .index = index, .generation = 1 };
    }
    pub fn valid(self: *const EntityStore, entity: Entity) bool {
        return entity.index < self.slots.items.len and self.slots.items[entity.index].generation == entity.generation and self.slots.items[entity.index].location != null;
    }
    pub fn location(self: *const EntityStore, entity: Entity) ?EntityLocation {
        if (!self.valid(entity)) return null;
        return self.slots.items[entity.index].location;
    }
    pub fn setLocation(self: *EntityStore, entity: Entity, value: EntityLocation) void {
        std.debug.assert(entity.index < self.slots.items.len);
        self.slots.items[entity.index].location = value;
    }
    pub fn destroy(self: *EntityStore, entity: Entity) error{StaleEntity}!void {
        if (!self.valid(entity)) return error.StaleEntity;
        const slot = &self.slots.items[entity.index];
        slot.location = null;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.next_free = self.free_head;
        self.free_head = entity.index;
    }
};
