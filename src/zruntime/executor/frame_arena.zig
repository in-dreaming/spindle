const std = @import("std");
const Counter = @import("counter.zig").Counter;

/// Three rotating caller-owned arenas. A frame can only be reset after its completion counter reaches zero.
pub const FrameArena = struct {
    allocator: std.mem.Allocator,
    arenas: [3]std.heap.ArenaAllocator,
    counters: [3]Counter = .{ .{}, .{}, .{} },
    current: usize = 0,
    pub fn init(allocator: std.mem.Allocator) FrameArena {
        return .{ .allocator = allocator, .arenas = .{ std.heap.ArenaAllocator.init(allocator), std.heap.ArenaAllocator.init(allocator), std.heap.ArenaAllocator.init(allocator) } };
    }
    pub fn deinit(self: *FrameArena) void {
        for (&self.arenas) |*arena| arena.deinit();
    }
    pub fn allocatorForCurrent(self: *FrameArena) std.mem.Allocator {
        return self.arenas[self.current].allocator();
    }
    pub fn counter(self: *FrameArena) *Counter {
        return &self.counters[self.current];
    }
    pub fn rotate(self: *FrameArena) !void {
        const next = (self.current + 1) % self.arenas.len;
        if (!self.counters[next].isComplete()) return error.FrameInFlight;
        _ = self.arenas[next].reset(.retain_capacity);
        self.current = next;
    }
};
