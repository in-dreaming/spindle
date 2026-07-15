const std = @import("std");
const entity = @import("entity.zig");
const registry = @import("component_registry.zig");
const signature = @import("signature.zig");

pub const ChangeVersion = u32;
pub const Column = struct { id: registry.ComponentTypeId, offset: usize, stride: usize, version: ChangeVersion = 0 };

/// A 16-byte aligned SoA chunk. It is exclusively mutated by its owning World during Task 08.
pub const Chunk = struct {
    allocator: std.mem.Allocator,
    storage: []align(16) u8,
    columns: std.ArrayListUnmanaged(Column) = .empty,
    entity_offset: usize,
    count: usize = 0,
    capacity: usize,
    pub fn init(allocator: std.mem.Allocator, components: []const registry.ComponentMeta, chunk_bytes: usize) !Chunk {
        const minimum = @max(chunk_bytes, 2048);
        var row_bytes: usize = @sizeOf(entity.Entity);
        for (components) |meta| row_bytes += if (meta.size == 0) 0 else std.mem.alignForward(usize, meta.size, 16);
        const capacity = @max(@as(usize, 1), minimum / @max(row_bytes, 1));
        var columns: std.ArrayListUnmanaged(Column) = .empty;
        errdefer columns.deinit(allocator);
        var offset: usize = 0;
        offset = std.mem.alignForward(usize, offset, @alignOf(entity.Entity));
        const entity_offset = offset;
        offset += capacity * @sizeOf(entity.Entity);
        for (components) |meta| {
            if (meta.size == 0) continue;
            offset = std.mem.alignForward(usize, offset, @max(meta.alignment, 16));
            try columns.append(allocator, .{ .id = meta.id, .offset = offset, .stride = meta.size });
            offset += capacity * meta.size;
        }
        const storage = try allocator.alignedAlloc(u8, .@"16", offset);
        return .{ .allocator = allocator, .storage = storage, .columns = columns, .entity_offset = entity_offset, .capacity = capacity };
    }
    pub fn deinit(self: *Chunk) void {
        self.columns.deinit(self.allocator);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
    pub fn entities(self: *Chunk) []entity.Entity {
        const ptr: [*]entity.Entity = @ptrCast(@alignCast(self.storage.ptr + self.entity_offset));
        return ptr[0..self.capacity];
    }
    pub fn column(self: *const Chunk, id: registry.ComponentTypeId) ?Column {
        for (self.columns.items) |entry| if (entry.id == id) return entry;
        return null;
    }
    pub fn valuePtr(self: *Chunk, id: registry.ComponentTypeId, row: usize) ?*anyopaque {
        const col = self.column(id) orelse return null;
        return @ptrCast(self.storage.ptr + col.offset + row * col.stride);
    }
    pub fn valueConstPtr(self: *const Chunk, id: registry.ComponentTypeId, row: usize) ?*const anyopaque {
        for (self.columns.items) |col| if (col.id == id) return @ptrCast(self.storage.ptr + col.offset + row * col.stride);
        return null;
    }
    pub fn markChanged(self: *Chunk, id: registry.ComponentTypeId, version: ChangeVersion) void {
        for (self.columns.items) |*entry| if (entry.id == id) {
            entry.version = version;
            return;
        };
    }
};
