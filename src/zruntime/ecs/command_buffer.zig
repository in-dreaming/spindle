const std = @import("std");
const World = @import("world.zig").World;
const Entity = @import("entity.zig").Entity;
const ComponentTypeId = @import("component_registry.zig").ComponentTypeId;
const Signature = @import("signature.zig").Signature;

pub const TempEntity = u64;
pub const EntityRef = union(enum) { entity: Entity, temp: TempEntity };
pub const Kind = enum { create, destroy, add, remove, set };
pub const Command = struct { sequence: u64, kind: Kind, target: EntityRef, component: ?ComponentTypeId = null, bytes: []u8 = &.{} };

/// Worker-local deferred structural commands. Values are copied at recording time and freed by deinit.
pub const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    sequence: *std.atomic.Value(u64),
    commands: std.ArrayListUnmanaged(Command) = .empty,
    next_temp: TempEntity = 0,
    buffer_id: u32,
    pub fn init(allocator: std.mem.Allocator, sequence: *std.atomic.Value(u64), buffer_id: u32) CommandBuffer {
        return .{ .allocator = allocator, .sequence = sequence, .buffer_id = buffer_id };
    }
    pub fn deinit(self: *CommandBuffer) void {
        for (self.commands.items) |item| self.allocator.free(item.bytes);
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn create(self: *CommandBuffer) !EntityRef {
        const target: EntityRef = .{ .temp = (@as(u64, self.buffer_id) << 32) | self.next_temp };
        self.next_temp += 1;
        try self.append(.create, target, null, &.{});
        return target;
    }
    pub fn destroy(self: *CommandBuffer, target: EntityRef) !void {
        try self.append(.destroy, target, null, &.{});
    }
    pub fn remove(self: *CommandBuffer, target: EntityRef, id: ComponentTypeId) !void {
        try self.append(.remove, target, id, &.{});
    }
    pub fn add(self: *CommandBuffer, target: EntityRef, id: ComponentTypeId, value: anytype) !void {
        try self.append(.add, target, id, std.mem.asBytes(&value));
    }
    pub fn set(self: *CommandBuffer, target: EntityRef, id: ComponentTypeId, value: anytype) !void {
        try self.append(.set, target, id, std.mem.asBytes(&value));
    }
    fn append(self: *CommandBuffer, kind: Kind, target: EntityRef, component: ?ComponentTypeId, bytes: []const u8) !void {
        const copy = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(copy);
        try self.commands.append(self.allocator, .{ .sequence = self.sequence.fetchAdd(1, .monotonic), .kind = kind, .target = target, .component = component, .bytes = copy });
    }
};

/// Owns the monotonic global command sequence and applies worker buffers in sequence order.
pub const CommandQueue = struct {
    allocator: std.mem.Allocator,
    sequence: std.atomic.Value(u64) = .init(0),
    next_buffer: std.atomic.Value(u32) = .init(0),
    pub fn init(allocator: std.mem.Allocator) CommandQueue {
        return .{ .allocator = allocator };
    }
    pub fn buffer(self: *CommandQueue) CommandBuffer {
        return CommandBuffer.init(self.allocator, &self.sequence, self.next_buffer.fetchAdd(1, .monotonic));
    }
    /// Merges buffers deterministically. Validation occurs before mutation; invalid batches leave the world untouched.
    pub fn apply(self: *CommandQueue, world: *World, buffers: []CommandBuffer) !void {
        _ = self;
        var all: std.ArrayListUnmanaged(*const Command) = .empty;
        defer all.deinit(world.allocator);
        for (buffers) |*worker_buffer| for (worker_buffer.commands.items) |*command| try all.append(world.allocator, command);
        std.mem.sort(*const Command, all.items, {}, struct {
            fn less(_: void, a: *const Command, b: *const Command) bool {
                return a.sequence < b.sequence;
            }
        }.less);
        var normalized = try normalize(world.allocator, all.items);
        defer normalized.deinit(world.allocator);
        try validate(world, normalized.items);
        var temp_entities: std.AutoHashMapUnmanaged(TempEntity, Entity) = .empty;
        defer temp_entities.deinit(world.allocator);
        var temp_count: usize = 0;
        for (normalized.items) |command| switch (command.target) {
            .temp => temp_count += 1,
            .entity => {},
        };
        // Map growth is fallible, so reserve it before the first structural mutation.
        try temp_entities.ensureTotalCapacity(world.allocator, std.math.cast(u32, temp_count) orelse return error.TooManyCommands);
        try reserveBatch(world, normalized.items);
        for (normalized.items) |command| {
            const target = switch (command.target) {
                .entity => |value| value,
                .temp => |temp| temp_entities.get(temp) orelse blk: {
                    const made = try world.create();
                    try temp_entities.put(world.allocator, temp, made);
                    break :blk made;
                },
            };
            switch (command.kind) {
                .create => {},
                .destroy => try world.destroy(target),
                .add => world.addRaw(target, command.component.?, command.bytes) catch |err| switch (err) {
                    error.AlreadyHasComponent => try world.setRaw(target, command.component.?, command.bytes),
                    else => return err,
                },
                .remove => world.remove(target, command.component.?) catch |err| switch (err) {
                    error.MissingComponent => {},
                    else => return err,
                },
                .set => try world.setRaw(target, command.component.?, command.bytes),
            }
        }
    }
};
/// Destroy has batch-wide precedence. For all other commands, the stable global sequence remains the tie breaker.
fn normalize(allocator: std.mem.Allocator, commands: []const *const Command) !std.ArrayListUnmanaged(*const Command) {
    var result: std.ArrayListUnmanaged(*const Command) = .empty;
    errdefer result.deinit(allocator);
    var emitted_destroys: std.ArrayListUnmanaged(EntityRef) = .empty;
    defer emitted_destroys.deinit(allocator);
    for (commands) |command| if (command.kind == .destroy and !containsRef(emitted_destroys.items, command.target)) try emitted_destroys.append(allocator, command.target);
    for (commands) |command| {
        if (containsRef(emitted_destroys.items, command.target)) {
            if (command.kind == .destroy and !containsCommandTarget(result.items, command.target)) try result.append(allocator, command);
            continue;
        }
        if (command.kind != .create) try result.append(allocator, command) else try result.append(allocator, command);
    }
    return result;
}
fn containsRef(values: []const EntityRef, needle: EntityRef) bool {
    for (values) |value| if (sameRef(value, needle)) return true;
    return false;
}
fn sameRef(a: EntityRef, b: EntityRef) bool {
    return switch (a) {
        .entity => |left| switch (b) {
            .entity => |right| left.index == right.index and left.generation == right.generation,
            .temp => false,
        },
        .temp => |left| switch (b) {
            .temp => |right| left == right,
            .entity => false,
        },
    };
}
fn containsCommandTarget(commands: []const *const Command, needle: EntityRef) bool {
    for (commands) |command| if (sameRef(command.target, needle)) return true;
    return false;
}
const Simulated = struct { target: EntityRef, sig: Signature };
const Need = struct { sig: Signature, rows: usize };
fn reserveBatch(world: *World, commands: []const *const Command) !void {
    var states: std.ArrayListUnmanaged(Simulated) = .empty;
    defer {
        for (states.items) |*state| state.sig.deinit();
        states.deinit(world.allocator);
    }
    var needs: std.ArrayListUnmanaged(Need) = .empty;
    defer {
        for (needs.items) |*need| need.sig.deinit();
        needs.deinit(world.allocator);
    }
    var creates: usize = 0;
    var edges: usize = 0;
    for (commands) |command| {
        if (command.kind == .destroy) continue;
        var state = try simulatedState(world, &states, command.target);
        switch (command.kind) {
            .create => creates += 1,
            .add => {
                _ = try state.sig.add(command.component.?);
                try addNeed(world.allocator, &needs, &state.sig);
                edges += 1;
            },
            .remove => {
                _ = state.sig.remove(command.component.?);
                try addNeed(world.allocator, &needs, &state.sig);
                edges += 1;
            },
            .set => {},
            .destroy => return error.InvalidCommand,
        }
    }
    var empty = Signature.init(world.allocator);
    defer empty.deinit();
    try world.reserveStructural(&empty, creates, creates, edges);
    for (needs.items) |*need| try world.reserveStructural(&need.sig, need.rows, 0, edges);
}
fn simulatedState(world: *const World, states: *std.ArrayListUnmanaged(Simulated), target: EntityRef) !*Simulated {
    for (states.items) |*state| if (sameRef(state.target, target)) return state;
    var sig = Signature.init(world.allocator);
    switch (target) {
        .entity => |value| {
            const location = world.entities.location(value) orelse return error.StaleEntity;
            sig.deinit();
            sig = try world.archetypes.items[location.archetype].signature.clone(world.allocator);
        },
        .temp => {},
    }
    try states.append(world.allocator, .{ .target = target, .sig = sig });
    return &states.items[states.items.len - 1];
}
fn addNeed(allocator: std.mem.Allocator, needs: *std.ArrayListUnmanaged(Need), sig: *const Signature) !void {
    for (needs.items) |*need| if (need.sig.eql(sig)) {
        need.rows += 1;
        return;
    };
    try needs.append(allocator, .{ .sig = try sig.clone(allocator), .rows = 1 });
}
fn validate(world: *const World, commands: []const *const Command) !void {
    for (commands) |command| {
        if (command.component) |id| {
            const meta = world.registry.find(id) orelse return error.UnknownComponent;
            if ((command.kind == .add or command.kind == .set) and command.bytes.len != meta.size) return error.ComponentSizeMismatch;
        }
        switch (command.target) {
            .entity => |value| if (!world.isAlive(value)) return error.StaleEntity,
            .temp => {},
        }
    }
}
