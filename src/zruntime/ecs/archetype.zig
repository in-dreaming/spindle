const std = @import("std");
const signature = @import("signature.zig");
const chunk = @import("chunk.zig");
const registry = @import("component_registry.zig");

/// Owns chunks for one exact component signature. Edge fields cache target archetype indices.
pub const Archetype = struct {
    allocator: std.mem.Allocator,
    signature: signature.Signature,
    chunks: std.ArrayListUnmanaged(chunk.Chunk) = .empty,
    add_edges: std.AutoHashMapUnmanaged(registry.ComponentTypeId, usize) = .empty,
    remove_edges: std.AutoHashMapUnmanaged(registry.ComponentTypeId, usize) = .empty,
    pub fn init(allocator: std.mem.Allocator, value: signature.Signature) Archetype {
        return .{ .allocator = allocator, .signature = value };
    }
    pub fn deinit(self: *Archetype) void {
        for (self.chunks.items) |*item| item.deinit();
        self.chunks.deinit(self.allocator);
        self.add_edges.deinit(self.allocator);
        self.remove_edges.deinit(self.allocator);
        self.signature.deinit();
        self.* = undefined;
    }
    pub fn allocateRow(self: *Archetype, metas: []const registry.ComponentMeta, chunk_bytes: usize) !struct { chunk_index: usize, row: usize } {
        for (self.chunks.items, 0..) |*item, i| if (item.count < item.capacity) {
            const row = item.count;
            item.count += 1;
            return .{ .chunk_index = i, .row = row };
        };
        try self.chunks.append(self.allocator, try chunk.Chunk.init(self.allocator, metas, chunk_bytes));
        self.chunks.items[self.chunks.items.len - 1].count = 1;
        return .{ .chunk_index = self.chunks.items.len - 1, .row = 0 };
    }
};
