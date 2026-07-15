const std = @import("std");

/// Stable, process-independent component identity derived from its explicit name.
pub const ComponentTypeId = u64;
pub const ComponentFlags = packed struct(u32) { external_handle: bool = false, _reserved: u31 = 0 };
pub const ComponentOps = struct {
    /// Constructs a destination from a source. The source remains valid on success and failure.
    clone: *const fn (destination: *anyopaque, source: *const anyopaque) anyerror!void,
    deinit: *const fn (value: *anyopaque) void,
};
/// Fixed-width snapshot conversion for components that contain external handles. The encoder must write only stable data.
pub const SnapshotCodec = struct {
    context: ?*anyopaque = null,
    encode: *const fn (?*anyopaque, *const anyopaque, []u8) anyerror!void,
    decode: *const fn (?*anyopaque, *anyopaque, []const u8) anyerror!void,
};
/// One explicitly registered schema step. Multi-version upgrades are applied one version at a time.
pub const SnapshotMigration = struct {
    from_version: u32,
    apply: *const fn (*anyopaque, []const u8) anyerror!void,
};
pub const SnapshotHooks = struct { codec: ?SnapshotCodec = null, migration: ?SnapshotMigration = null };
pub const ComponentMeta = struct { id: ComponentTypeId, name: []const u8, size: usize, alignment: usize, schema_version: u32, flags: ComponentFlags, ops: ComponentOps, snapshot: SnapshotHooks = .{} };
pub const Error = error{ Frozen, DuplicateId, DuplicateName, UnknownComponent, InvalidName };

fn noopDeinit(_: *anyopaque) void {}
fn copyBytes(destination: *anyopaque, source: *const anyopaque) anyerror!void {
    // The typed wrapper below selects this only for bytewise-copyable values.
    _ = destination;
    _ = source;
}
fn stableHash(name: []const u8) ComponentTypeId {
    return std.hash.Fnv1a_64.hash(name);
}

/// Setup-time component metadata registry. Frozen registry lookups are read-only.
pub const ComponentRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(ComponentMeta) = .empty,
    frozen: bool = false,
    version: u64 = 0,
    pub fn init(allocator: std.mem.Allocator) ComponentRegistry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *ComponentRegistry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn freeze(self: *ComponentRegistry) void {
        self.frozen = true;
    }
    pub fn find(self: *const ComponentRegistry, id: ComponentTypeId) ?*const ComponentMeta {
        for (self.entries.items) |*entry| if (entry.id == id) return entry;
        return null;
    }
    pub fn register(self: *ComponentRegistry, meta: ComponentMeta) (Error || std.mem.Allocator.Error)!void {
        if (self.frozen) return error.Frozen;
        if (meta.name.len == 0) return error.InvalidName;
        for (self.entries.items) |entry| {
            if (entry.id == meta.id) return error.DuplicateId;
            if (std.mem.eql(u8, entry.name, meta.name)) return error.DuplicateName;
        }
        try self.entries.append(self.allocator, meta);
        self.version +%= 1;
    }
    /// Registers T using an explicit stable name. The default lifecycle is bytewise copy and no destruction.
    pub fn registerType(self: *ComponentRegistry, comptime T: type, name: []const u8, schema_version: u32, flags: ComponentFlags) (Error || std.mem.Allocator.Error)!ComponentTypeId {
        const Wrapper = struct {
            fn clone(destination: *anyopaque, source: *const anyopaque) anyerror!void {
                const dst: *T = @ptrCast(@alignCast(destination));
                const src: *const T = @ptrCast(@alignCast(source));
                dst.* = src.*;
            }
        };
        const id = stableHash(name);
        try self.register(.{ .id = id, .name = name, .size = @sizeOf(T), .alignment = @alignOf(T), .schema_version = schema_version, .flags = flags, .ops = .{ .clone = Wrapper.clone, .deinit = noopDeinit } });
        return id;
    }
    pub fn idFor(name: []const u8) ComponentTypeId {
        return stableHash(name);
    }
};
