const std = @import("std");
const registry = @import("component_registry.zig");
pub const ComponentTypeId = registry.ComponentTypeId;

/// Sorted component set with a compact bloom-style bitset used as a fast rejection path.
pub const Signature = struct {
    allocator: std.mem.Allocator,
    ids: std.ArrayListUnmanaged(ComponentTypeId) = .empty,
    bits: [4]u64 = [_]u64{0} ** 4,
    pub fn init(allocator: std.mem.Allocator) Signature {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Signature) void {
        self.ids.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn clone(self: *const Signature, allocator: std.mem.Allocator) !Signature {
        var result = Signature.init(allocator);
        errdefer result.deinit();
        try result.ids.appendSlice(allocator, self.ids.items);
        result.bits = self.bits;
        return result;
    }
    pub fn contains(self: *const Signature, id: ComponentTypeId) bool {
        const bit: u8 = @truncate(id);
        if ((self.bits[bit / 64] & (@as(u64, 1) << @intCast(bit % 64))) == 0) return false;
        for (self.ids.items) |current| if (current == id) return true;
        return false;
    }
    pub fn add(self: *Signature, id: ComponentTypeId) !bool {
        if (self.contains(id)) return false;
        var at: usize = 0;
        while (at < self.ids.items.len and self.ids.items[at] < id) : (at += 1) {}
        try self.ids.insert(self.allocator, at, id);
        const bit: u8 = @truncate(id);
        self.bits[bit / 64] |= @as(u64, 1) << @intCast(bit % 64);
        return true;
    }
    pub fn remove(self: *Signature, id: ComponentTypeId) bool {
        for (self.ids.items, 0..) |current, i| if (current == id) {
            _ = self.ids.orderedRemove(i);
            const bit: u8 = @truncate(id);
            self.bits[bit / 64] &= ~(@as(u64, 1) << @intCast(bit % 64));
            return true;
        };
        return false;
    }
    pub fn eql(a: *const Signature, b: *const Signature) bool {
        return std.mem.eql(ComponentTypeId, a.ids.items, b.ids.items);
    }
    pub fn hash(self: *const Signature) u64 {
        return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(self.ids.items));
    }
};
