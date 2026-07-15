const std = @import("std");
const Mutex = @import("../sync/adaptive_mutex.zig").AdaptiveMutex;

/// Declared resource use. Units are selected by the caller and must match its budget.
pub const ResourceCost = struct { memory: u64 = 0, disk: u64 = 0, network: u64 = 0, device: u64 = 0 };

/// A single device/backend budget. Reservations are all-or-nothing under its lock.
pub const ExecutionBudget = struct {
    capacity: ResourceCost,
    used: ResourceCost = .{},
    lock: Mutex = .{},

    pub fn init(capacity: ResourceCost) ExecutionBudget {
        return .{ .capacity = capacity };
    }
    pub fn canEverFit(self: *const ExecutionBudget, cost: ResourceCost) bool {
        return cost.memory <= self.capacity.memory and cost.disk <= self.capacity.disk and cost.network <= self.capacity.network and cost.device <= self.capacity.device;
    }
    /// Atomically reserves every dimension, or no dimension.
    pub fn reserve(self: *ExecutionBudget, cost: ResourceCost) bool {
        self.lock.lock();
        defer self.lock.unlock();
        if (cost.memory > self.capacity.memory -| self.used.memory or cost.disk > self.capacity.disk -| self.used.disk or cost.network > self.capacity.network -| self.used.network or cost.device > self.capacity.device -| self.used.device) return false;
        self.used.memory += cost.memory;
        self.used.disk += cost.disk;
        self.used.network += cost.network;
        self.used.device += cost.device;
        return true;
    }
    pub fn release(self: *ExecutionBudget, cost: ResourceCost) void {
        self.lock.lock();
        defer self.lock.unlock();
        std.debug.assert(cost.memory <= self.used.memory and cost.disk <= self.used.disk and cost.network <= self.used.network and cost.device <= self.used.device);
        self.used.memory -= cost.memory;
        self.used.disk -= cost.disk;
        self.used.network -= cost.network;
        self.used.device -= cost.device;
    }
    pub fn snapshot(self: *ExecutionBudget) ResourceCost {
        self.lock.lock();
        defer self.lock.unlock();
        return self.used;
    }
};

test "budget reservations are all or nothing" {
    var budget = ExecutionBudget.init(.{ .memory = 4, .disk = 2 });
    try std.testing.expect(budget.reserve(.{ .memory = 3, .disk = 1 }));
    try std.testing.expect(!budget.reserve(.{ .memory = 2, .disk = 1 }));
    try std.testing.expectEqual(@as(u64, 3), budget.snapshot().memory);
    budget.release(.{ .memory = 3, .disk = 1 });
    try std.testing.expectEqual(@as(u64, 0), budget.snapshot().memory);
}
