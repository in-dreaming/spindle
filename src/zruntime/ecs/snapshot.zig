const std = @import("std");
const core = @import("../core/root.zig");
const World = @import("world.zig").World;
const Entity = @import("entity.zig").Entity;
const EntitySlot = @import("entity.zig").EntitySlot;
const EntityStore = @import("entity.zig").EntityStore;
const Archetype = @import("archetype.zig").Archetype;
const Chunk = @import("chunk.zig").Chunk;
const Signature = @import("signature.zig").Signature;

/// Stable envelope schema for ECS full snapshots.
pub const schema = core.schema.SchemaKey{ .id = 0x6563_732e_736e_6170, .version = 1 };
pub const max_payload_len: usize = 64 * 1024 * 1024;

/// An owned, envelope-encoded complete ECS state image. It contains no process pointers.
pub const Snapshot = struct {
    bytes: []u8,
    hash: u64,
    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

/// Encodes ECS storage in canonical archetype, chunk, and component-id order.
/// Registered components must be bytewise components; external handles require a task-specific codec.
pub fn capture(allocator: std.mem.Allocator, world: *const World) !Snapshot {
    for (world.registry.entries.items) |meta| if (meta.flags.external_handle and meta.snapshot.codec == null) return error.ExternalHandleRequiresCodec;
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);
    var w = Writer{ .bytes = &payload, .allocator = allocator };
    try w.u32(1);
    try w.u64(world.chunk_bytes);
    try w.u32(@intCast(world.registry.entries.items.len));
    const metas = try allocator.dupe(@TypeOf(world.registry.entries.items[0]), world.registry.entries.items);
    defer allocator.free(metas);
    std.mem.sort(@TypeOf(metas[0]), metas, {}, metaLess);
    for (metas) |meta| {
        try w.u64(meta.id);
        try w.u32(meta.schema_version);
        try w.u64(meta.size);
        try w.u64(meta.alignment);
        try w.bytesWithLen(meta.name);
    }
    const order = try allocator.alloc(usize, world.archetypes.items.len);
    defer allocator.free(order);
    for (order, 0..) |*item, i| item.* = i;
    std.mem.sort(usize, order, world, archLess);
    try w.u32(@intCast(order.len));
    for (order) |index| {
        const arch = &world.archetypes.items[index];
        try w.u32(@intCast(arch.signature.ids.items.len));
        for (arch.signature.ids.items) |id| try w.u64(id);
        try w.u32(@intCast(arch.chunks.items.len));
        for (arch.chunks.items) |*chunk| {
            try w.u32(@intCast(chunk.count));
            for (chunk.entities()[0..chunk.count]) |value| {
                try w.u32(value.index);
                try w.u32(value.generation);
            }
            for (arch.signature.ids.items) |id| {
                const meta = world.registry.find(id) orelse return error.UnknownComponent;
                if (meta.size == 0) continue;
                for (0..chunk.count) |row| {
                    const source = chunk.valueConstPtr(id, row).?;
                    if (meta.snapshot.codec) |codec| {
                        const encoded_value = try allocator.alloc(u8, meta.size);
                        defer allocator.free(encoded_value);
                        try codec.encode(codec.context, source, encoded_value);
                        try w.raw(encoded_value);
                    } else try w.raw(@as([*]const u8, @ptrCast(source))[0..meta.size]);
                }
            }
        }
    }
    const encoded = try core.schema.encode(allocator, schema, payload.items);
    return .{ .hash = core.hash.content(encoded), .bytes = encoded };
}

/// Returns a stable canonical hash for the complete ECS state.
pub fn canonicalHash(allocator: std.mem.Allocator, world: *const World) !u64 {
    var value = try capture(allocator, world);
    defer value.deinit(allocator);
    return value.hash;
}

/// Decodes and validates a snapshot before replacing ECS storage. On error, `world` is unchanged.
pub fn restore(world: *World, input: []const u8) !void {
    const envelope = try core.schema.decode(input, max_payload_len);
    if (envelope.schema.id != schema.id or envelope.schema.version != schema.version) return error.UnsupportedSnapshotSchema;
    var reader = Reader{ .input = envelope.payload };
    if (try reader.u32() != 1) return error.UnsupportedSnapshotVersion;
    const chunk_bytes: usize = @intCast(try reader.u64());
    if (chunk_bytes < 2048) return error.InvalidChunkBytes;
    const schema_versions = try validateSchema(world, &reader);
    defer world.allocator.free(schema_versions);
    var candidate = Candidate.init(world.allocator, chunk_bytes);
    errdefer candidate.deinit();
    const arch_count = try reader.count();
    if (arch_count == 0) return error.InvalidArchetypeTable;
    try candidate.archetypes.ensureTotalCapacity(world.allocator, arch_count);
    var seen_empty = false;
    for (0..arch_count) |arch_index| {
        var sig = Signature.init(world.allocator);
        errdefer sig.deinit();
        const component_count = try reader.count();
        for (0..component_count) |_| {
            const id = try reader.u64();
            if (world.registry.find(id) == null) return error.UnknownComponent;
            if (!(try sig.add(id))) return error.InvalidSignature;
        }
        if (component_count == 0) {
            if (seen_empty) return error.InvalidArchetypeTable;
            seen_empty = true;
        }
        var arch = Archetype.init(world.allocator, sig);
        errdefer arch.deinit();
        const chunks = try reader.count();
        for (0..chunks) |_| {
            const metas = try metasFor(world, &arch.signature);
            defer world.allocator.free(metas);
            var chunk = try Chunk.init(world.allocator, metas, chunk_bytes);
            errdefer chunk.deinit();
            const rows = try reader.count();
            if (rows > chunk.capacity) return error.InvalidChunkCount;
            chunk.count = rows;
            for (0..rows) |row| {
                const value = Entity{ .index = try reader.u32(), .generation = try reader.u32() };
                if (value.generation == 0) return error.InvalidEntity;
                chunk.entities()[row] = value;
                try candidate.recordEntity(value, .{ .archetype = arch_index, .chunk = arch.chunks.items.len, .row = row });
            }
            for (arch.signature.ids.items) |id| {
                const meta = world.registry.find(id).?;
                if (meta.size == 0) continue;
                for (0..rows) |row| {
                    const destination = chunk.valuePtr(id, row).?;
                    const source_version = try schemaVersion(schema_versions, id);
                    if (source_version != meta.schema_version) {
                        if (meta.snapshot.codec != null) return error.UnsupportedMigrationCodecCombination;
                        const encoded_value = try world.allocator.alloc(u8, meta.size);
                        defer world.allocator.free(encoded_value);
                        try reader.raw(encoded_value);
                        const migration = meta.snapshot.migration orelse return error.MissingMigration;
                        try migration.apply(destination, encoded_value);
                        continue;
                    }
                    if (meta.flags.external_handle and meta.snapshot.codec == null) return error.ExternalHandleRequiresCodec;
                    if (meta.snapshot.codec) |codec| {
                        const encoded_value = try reader.take(meta.size);
                        try codec.decode(codec.context, destination, encoded_value);
                    } else try reader.raw(@as([*]u8, @ptrCast(destination))[0..meta.size]);
                }
            }
            try arch.chunks.append(world.allocator, chunk);
        }
        try candidate.archetypes.append(world.allocator, arch);
    }
    if (!seen_empty or !reader.done()) return error.InvalidSnapshot;
    candidate.finishFreeList();
    // All allocations and validation are complete. This is the sole mutation of the live storage.
    for (world.archetypes.items) |*arch| arch.deinit();
    world.archetypes.deinit(world.allocator);
    world.entities.deinit();
    world.archetypes = candidate.archetypes;
    world.entities = candidate.entities;
    world.chunk_bytes = chunk_bytes;
    world.archetype_version +%= 1;
    candidate.disarm();
}

/// One structural or changed-column operation in a base-bound incremental image.
pub const DeltaOp = struct { kind: enum { create, destroy, add, remove, set }, entity: Entity, component: ?u64 = null, bytes: []u8 = &.{} };
/// A real changed-column incremental image. It is valid only for the exact canonical base state.
pub const Incremental = struct {
    base_hash: u64,
    target_hash: u64,
    operations: []DeltaOp,
    pub fn deinit(self: *Incremental, allocator: std.mem.Allocator) void {
        for (self.operations) |op| allocator.free(op.bytes);
        allocator.free(self.operations);
        self.* = undefined;
    }
};
pub fn captureIncremental(allocator: std.mem.Allocator, world: *const World, base: *const Snapshot) !Incremental {
    var previous = try cloneForSnapshot(allocator, world);
    defer previous.deinit();
    try restore(&previous, base.bytes);
    var operations: std.ArrayListUnmanaged(DeltaOp) = .empty;
    errdefer {
        for (operations.items) |op| allocator.free(op.bytes);
        operations.deinit(allocator);
    }
    const slots = @max(previous.entities.slots.items.len, world.entities.slots.items.len);
    for (0..slots) |index| {
        const before = entityAt(&previous, index);
        const after = entityAt(world, index);
        if (before == null and after == null) continue;
        if (before) |value| if (after == null or !sameEntity(value, after.?)) {
            try appendOp(allocator, &operations, .destroy, value, null, &.{});
            if (after == null) continue;
        };
        if (after) |value| {
            if (before == null or !sameEntity(before.?, value)) {
                try appendOp(allocator, &operations, .create, value, null, &.{});
                try appendAllComponents(allocator, &operations, world, value, .add);
            } else try appendDifferences(allocator, &operations, &previous, world, value);
        }
    }
    return .{ .base_hash = base.hash, .target_hash = try canonicalHash(allocator, world), .operations = try operations.toOwnedSlice(allocator) };
}
/// Applies the changed-column delta only to its exact base. Generated deltas are ordered create/destroy/migration/value-safe.
pub fn applyIncremental(allocator: std.mem.Allocator, world: *World, change: *const Incremental) !void {
    if (try canonicalHash(allocator, world) != change.base_hash) return error.BaseMismatch;
    for (change.operations) |op| switch (op.kind) {
        .create => {
            const made = try world.create();
            if (!sameEntity(made, op.entity)) return error.DeltaEntityMismatch;
        },
        .destroy => try world.destroy(op.entity),
        .add => try world.addRaw(op.entity, op.component.?, op.bytes),
        .remove => try world.remove(op.entity, op.component.?),
        .set => try world.setRaw(op.entity, op.component.?, op.bytes),
    };
    if (try canonicalHash(allocator, world) != change.target_hash) return error.DeltaHashMismatch;
}
fn cloneForSnapshot(allocator: std.mem.Allocator, source: *const World) !World {
    var result = try World.init(allocator, .{ .chunk_bytes = source.chunk_bytes });
    errdefer result.deinit();
    for (source.registry.entries.items) |meta| try result.registry.register(meta);
    return result;
}
fn entityAt(world: *const World, index: usize) ?Entity {
    if (index >= world.entities.slots.items.len) return null;
    const slot = world.entities.slots.items[index];
    if (slot.location == null) return null;
    return .{ .index = @intCast(index), .generation = slot.generation };
}
fn sameEntity(a: Entity, b: Entity) bool {
    return a.index == b.index and a.generation == b.generation;
}
fn appendOp(allocator: std.mem.Allocator, ops: *std.ArrayListUnmanaged(DeltaOp), kind: DeltaOp.kind, value: Entity, component: ?u64, bytes: []const u8) !void {
    try ops.append(allocator, .{ .kind = kind, .entity = value, .component = component, .bytes = try allocator.dupe(u8, bytes) });
}
fn appendAllComponents(allocator: std.mem.Allocator, ops: *std.ArrayListUnmanaged(DeltaOp), world: *const World, value: Entity, kind: DeltaOp.kind) !void {
    const location = world.entities.location(value).?;
    const arch = &world.archetypes.items[location.archetype];
    for (arch.signature.ids.items) |id| {
        const meta = world.registry.find(id).?;
        const bytes = if (meta.size == 0) &.{} else @as([*]const u8, @ptrCast(arch.chunks.items[location.chunk].valueConstPtr(id, location.row).?))[0..meta.size];
        try appendOp(allocator, ops, kind, value, id, bytes);
    }
}
fn appendDifferences(allocator: std.mem.Allocator, ops: *std.ArrayListUnmanaged(DeltaOp), before: *const World, after: *const World, value: Entity) !void {
    const old_location = before.entities.location(value).?;
    const new_location = after.entities.location(value).?;
    const old_arch = &before.archetypes.items[old_location.archetype];
    const new_arch = &after.archetypes.items[new_location.archetype];
    for (old_arch.signature.ids.items) |id| if (!new_arch.signature.contains(id)) try appendOp(allocator, ops, .remove, value, id, &.{});
    for (new_arch.signature.ids.items) |id| {
        const meta = after.registry.find(id).?;
        const new_bytes = if (meta.size == 0) &.{} else @as([*]const u8, @ptrCast(new_arch.chunks.items[new_location.chunk].valueConstPtr(id, new_location.row).?))[0..meta.size];
        if (!old_arch.signature.contains(id)) {
            try appendOp(allocator, ops, .add, value, id, new_bytes);
            continue;
        }
        if (meta.size != 0) {
            const old_bytes = @as([*]const u8, @ptrCast(old_arch.chunks.items[old_location.chunk].valueConstPtr(id, old_location.row).?))[0..meta.size];
            if (!std.mem.eql(u8, old_bytes, new_bytes)) try appendOp(allocator, ops, .set, value, id, new_bytes);
        }
    }
}

fn metaLess(_: void, a: anytype, b: @TypeOf(a)) bool {
    return a.id < b.id;
}
fn archLess(world: *const World, a: usize, b: usize) bool {
    const left = world.archetypes.items[a].signature.ids.items;
    const right = world.archetypes.items[b].signature.ids.items;
    const n = @min(left.len, right.len);
    for (0..n) |i| if (left[i] != right[i]) return left[i] < right[i];
    return left.len < right.len;
}
fn metasFor(world: *const World, sig: *const Signature) ![]@import("component_registry.zig").ComponentMeta {
    const result = try world.allocator.alloc(@import("component_registry.zig").ComponentMeta, sig.ids.items.len);
    errdefer world.allocator.free(result);
    for (sig.ids.items, 0..) |id, i| result[i] = (world.registry.find(id) orelse return error.UnknownComponent).*;
    return result;
}
const SchemaVersion = struct { id: u64, version: u32 };
fn validateSchema(world: *const World, r: *Reader) ![]SchemaVersion {
    const count = try r.count();
    if (count != world.registry.entries.items.len) return error.SchemaMismatch;
    const versions = try world.allocator.alloc(SchemaVersion, count);
    errdefer world.allocator.free(versions);
    var previous: u64 = 0;
    for (0..count) |i| {
        const id = try r.u64();
        const version = try r.u32();
        const size: usize = @intCast(try r.u64());
        const alignment: usize = @intCast(try r.u64());
        const name = try r.bytesWithLen();
        const meta = world.registry.find(id) orelse return error.UnknownComponent;
        if ((i != 0 and id <= previous) or meta.size != size or meta.alignment != alignment or !std.mem.eql(u8, meta.name, name)) return error.SchemaMismatch;
        if (meta.schema_version != version) {
            const migration = meta.snapshot.migration orelse return error.MissingMigration;
            if (migration.from_version != version or version + 1 != meta.schema_version) return error.MigrationGap;
        }
        versions[i] = .{ .id = id, .version = version };
        previous = id;
    }
    return versions;
}
fn schemaVersion(versions: []const SchemaVersion, id: u64) !u32 {
    for (versions) |entry| if (entry.id == id) return entry.version;
    return error.SchemaMismatch;
}
const Candidate = struct {
    allocator: std.mem.Allocator,
    archetypes: std.ArrayListUnmanaged(Archetype) = .empty,
    entities: EntityStore,
    fn init(allocator: std.mem.Allocator, chunk_bytes: usize) Candidate {
        _ = chunk_bytes;
        return .{ .allocator = allocator, .entities = EntityStore.init(allocator) };
    }
    fn deinit(self: *Candidate) void {
        for (self.archetypes.items) |*item| item.deinit();
        self.archetypes.deinit(self.allocator);
        self.entities.deinit();
    }
    fn disarm(self: *Candidate) void {
        self.archetypes = .empty;
        self.entities = EntityStore.init(self.allocator);
    }
    fn recordEntity(self: *Candidate, value: Entity, location: @import("entity.zig").EntityLocation) !void {
        const required: usize = @as(usize, value.index) + 1;
        try self.entities.slots.ensureTotalCapacity(self.allocator, required);
        while (self.entities.slots.items.len < required) try self.entities.slots.append(self.allocator, .{});
        const slot = &self.entities.slots.items[value.index];
        if (slot.location != null) return error.DuplicateEntity;
        slot.* = .{ .generation = value.generation, .location = location };
    }
    fn finishFreeList(self: *Candidate) void {
        self.entities.free_head = null;
        var i = self.entities.slots.items.len;
        while (i > 0) {
            i -= 1;
            const slot = &self.entities.slots.items[i];
            if (slot.location == null) {
                slot.next_free = self.entities.free_head;
                self.entities.free_head = @intCast(i);
            }
        }
    }
};
const Writer = struct {
    bytes: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    fn raw(self: *Writer, value: []const u8) !void {
        try self.bytes.appendSlice(self.allocator, value);
    }
    fn @"u32"(self: *Writer, value: u32) !void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, value, .big);
        try self.raw(&b);
    }
    fn @"u64"(self: *Writer, value: u64) !void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, value, .big);
        try self.raw(&b);
    }
    fn bytesWithLen(self: *Writer, value: []const u8) !void {
        if (value.len > max_payload_len) return error.LengthTooLarge;
        try self.u32(@intCast(value.len));
        try self.raw(value);
    }
};
const Reader = struct {
    input: []const u8,
    at: usize = 0,
    fn raw(self: *Reader, target: []u8) !void {
        if (target.len > self.input.len -| self.at) return error.Truncated;
        @memcpy(target, self.input[self.at..][0..target.len]);
        self.at += target.len;
    }
    fn take(self: *Reader, n: usize) ![]const u8 {
        if (n > self.input.len -| self.at) return error.Truncated;
        const out = self.input[self.at..][0..n];
        self.at += n;
        return out;
    }
    fn @"u32"(self: *Reader) !u32 {
        return std.mem.readInt(u32, try self.take(4), .big);
    }
    fn @"u64"(self: *Reader) !u64 {
        return std.mem.readInt(u64, try self.take(8), .big);
    }
    fn count(self: *Reader) !usize {
        const result: usize = @intCast(try self.u32());
        if (result > max_payload_len) return error.LengthTooLarge;
        return result;
    }
    fn bytesWithLen(self: *Reader) ![]const u8 {
        return self.take(try self.count());
    }
    fn done(self: *const Reader) bool {
        return self.at == self.input.len;
    }
};

test "snapshot round trip retains entities, stale slots, and canonical bytes" {
    const Position = struct { x: i32 };
    var source = try World.init(std.testing.allocator, .{});
    defer source.deinit();
    const position = try source.registerComponent(Position, "snapshot.position");
    const stale = try source.create();
    try source.destroy(stale);
    const alive = try source.create();
    try source.add(alive, position, Position{ .x = 17 });
    var image = try capture(std.testing.allocator, &source);
    defer image.deinit(std.testing.allocator);
    var restored = try World.init(std.testing.allocator, .{});
    defer restored.deinit();
    _ = try restored.registerComponent(Position, "snapshot.position");
    try restore(&restored, image.bytes);
    try std.testing.expect(!restored.isAlive(stale));
    try std.testing.expect(restored.isAlive(alive));
    try std.testing.expectEqual(@as(i32, 17), (try restored.get(alive, position, Position)).x);
    try std.testing.expectEqual(image.hash, try canonicalHash(std.testing.allocator, &restored));
}

test "corrupt restore and mismatched increment leave the destination unchanged" {
    const Value = struct { value: u32 };
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();
    const id = try world.registerComponent(Value, "snapshot.atomic-value");
    const entity = try world.create();
    try world.add(entity, id, Value{ .value = 3 });
    var base = try capture(std.testing.allocator, &world);
    defer base.deinit(std.testing.allocator);
    try world.set(entity, id, Value{ .value = 9 });
    var changed = try captureIncremental(std.testing.allocator, &world, &base);
    defer changed.deinit(std.testing.allocator);
    try world.set(entity, id, Value{ .value = 12 });
    try std.testing.expectError(error.BaseMismatch, applyIncremental(std.testing.allocator, &world, &changed));
    try std.testing.expectEqual(@as(u32, 12), (try world.get(entity, id, Value)).value);
    var corrupt = try std.testing.allocator.dupe(u8, base.bytes);
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] +%= 1;
    try std.testing.expectError(error.ChecksumMismatch, restore(&world, corrupt));
    try std.testing.expectEqual(@as(u32, 12), (try world.get(entity, id, Value)).value);
    try restore(&world, base.bytes);
    try applyIncremental(std.testing.allocator, &world, &changed);
    try std.testing.expectEqual(@as(u32, 9), (try world.get(entity, id, Value)).value);
}

const HookValue = struct { handle: u64 };
fn hookClone(destination: *anyopaque, source: *const anyopaque) anyerror!void {
    @as(*HookValue, @ptrCast(@alignCast(destination))).* = @as(*const HookValue, @ptrCast(@alignCast(source))).*;
}
fn hookDeinit(_: *anyopaque) void {}
fn hookEncode(_: ?*anyopaque, source: *const anyopaque, output: []u8) anyerror!void {
    @memcpy(output, std.mem.asBytes(@as(*const HookValue, @ptrCast(@alignCast(source)))));
}
fn hookDecode(_: ?*anyopaque, destination: *anyopaque, input: []const u8) anyerror!void {
    const value = std.mem.readInt(u64, input[0..8], .native);
    if (value == 0) return error.MissingExternalHandle;
    @as(*HookValue, @ptrCast(@alignCast(destination))).* = .{ .handle = value };
}
fn failedMigration(_: *anyopaque, _: []const u8) anyerror!void {
    return error.MigrationFailed;
}
fn registerHookValue(world: *World, name: []const u8, version: u32, external: bool, migration: bool) !u64 {
    const registry = @import("component_registry.zig");
    const id = world.componentId(name);
    try world.registry.register(.{ .id = id, .name = name, .size = @sizeOf(HookValue), .alignment = @alignOf(HookValue), .schema_version = version, .flags = .{ .external_handle = external }, .ops = .{ .clone = hookClone, .deinit = hookDeinit }, .snapshot = .{ .codec = if (external) .{ .encode = hookEncode, .decode = hookDecode } else null, .migration = if (migration) .{ .from_version = 1, .apply = failedMigration } else null } });
    _ = registry;
    return id;
}
test "external resolver failure leaves the live world unchanged" {
    var source = try World.init(std.testing.allocator, .{});
    defer source.deinit();
    const id = try registerHookValue(&source, "snapshot.external", 1, true, false);
    const source_entity = try source.create();
    try source.add(source_entity, id, HookValue{ .handle = 0 });
    var image = try capture(std.testing.allocator, &source);
    defer image.deinit(std.testing.allocator);
    var destination = try World.init(std.testing.allocator, .{});
    defer destination.deinit();
    const target_id = try registerHookValue(&destination, "snapshot.external", 1, true, false);
    const target = try destination.create();
    try destination.add(target, target_id, HookValue{ .handle = 7 });
    try std.testing.expectError(error.MissingExternalHandle, restore(&destination, image.bytes));
    try std.testing.expectEqual(@as(u64, 7), (try destination.get(target, target_id, HookValue)).handle);
}
test "migration failure leaves the live world unchanged" {
    var source = try World.init(std.testing.allocator, .{});
    defer source.deinit();
    const id = try registerHookValue(&source, "snapshot.migration", 2, false, false);
    const entity = try source.create();
    try source.add(entity, id, HookValue{ .handle = 4 });
    var image = try capture(std.testing.allocator, &source);
    defer image.deinit(std.testing.allocator);
    std.mem.writeInt(u32, image.bytes[54..58], 1, .big);
    std.mem.writeInt(u64, image.bytes[22..30], core.hash.content(image.bytes[core.schema.header_len..]), .big);
    var destination = try World.init(std.testing.allocator, .{});
    defer destination.deinit();
    const target_id = try registerHookValue(&destination, "snapshot.migration", 2, false, true);
    const target = try destination.create();
    try destination.add(target, target_id, HookValue{ .handle = 8 });
    try std.testing.expectError(error.MigrationFailed, restore(&destination, image.bytes));
    try std.testing.expectEqual(@as(u64, 8), (try destination.get(target, target_id, HookValue)).handle);
}
