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
/// Archetype chunk queries and incremental query plans.
pub const query = @import("query.zig");
/// Deterministic deferred structural commands.
pub const command_buffer = @import("command_buffer.zig");
/// Immediate and frame-scoped event channels.
pub const event = @import("event.zig");
pub const Entity = entity.Entity;
pub const ComponentTypeId = component_registry.ComponentTypeId;
pub const World = world.World;
pub const Query = query.Query;
pub const QueryPlan = query.QueryPlan;
pub const CommandQueue = command_buffer.CommandQueue;
