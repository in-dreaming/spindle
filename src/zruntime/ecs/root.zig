/// Generational entity handles and locations.
pub const entity = @import("entity.zig");
/// Stable component metadata registry.
pub const component_registry = @import("component_registry.zig");
/// Archetype component signatures.
pub const signature = @import("signature.zig");
/// Aligned SoA chunk storage.
pub const chunk = @import("chunk.zig");
/// Archetype and edge cache ownership.
pub const archetype = @import("archetype.zig");
/// Single-threaded ECS storage world.
pub const world = @import("world.zig");
pub const Entity = entity.Entity;
pub const ComponentTypeId = component_registry.ComponentTypeId;
pub const World = world.World;
