const std = @import("std");

const Lock = struct {
    held: std.atomic.Value(bool) = .init(false),
    fn lock(self: *Lock) void {
        while (self.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    fn unlock(self: *Lock) void {
        self.held.store(false, .release);
    }
};

/// Fixed-capacity object slab. Acquired objects belong to the caller until release; release may occur on another thread.
pub fn Slab(comptime T: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        values: []T,
        free_indices: []usize,
        in_use: []bool,
        worker_local: []?usize,
        free_len: usize,
        mutex: Lock = .{},
        pub fn init(allocator: std.mem.Allocator, capacity: usize) !Self {
            return initWithWorkers(allocator, capacity, 0);
        }
        /// Creates a slab with one caller-owned local cache slot per worker. Worker indices must remain stable for the slab lifetime.
        pub fn initWithWorkers(allocator: std.mem.Allocator, capacity: usize, worker_count: usize) !Self {
            if (capacity == 0) return error.InvalidCapacity;
            const values = try allocator.alignedAlloc(T, std.mem.Alignment.of(T), capacity);
            errdefer allocator.free(values);
            const free_indices = try allocator.alloc(usize, capacity);
            errdefer allocator.free(free_indices);
            const in_use = try allocator.alloc(bool, capacity);
            errdefer allocator.free(in_use);
            const worker_local = try allocator.alloc(?usize, worker_count);
            errdefer allocator.free(worker_local);
            for (free_indices, 0..) |*index, i| index.* = capacity - i - 1;
            @memset(in_use, false);
            @memset(worker_local, null);
            return .{ .allocator = allocator, .values = values, .free_indices = free_indices, .in_use = in_use, .worker_local = worker_local, .free_len = capacity };
        }
        /// Caller supplies destruction for every object that was not returned.
        pub fn deinit(self: *Self, comptime dispose: fn (*T) void) void {
            for (self.in_use, 0..) |used, i| if (used) dispose(&self.values[i]);
            self.allocator.free(self.in_use);
            self.allocator.free(self.free_indices);
            self.allocator.free(self.worker_local);
            self.allocator.free(self.values);
        }
        pub fn acquire(self: *Self) error{OutOfMemory}!*T {
            return self.acquireImpl(null);
        }
        /// Acquires from the specified worker's local cache before the shared pool.
        pub fn acquireFor(self: *Self, worker: usize) error{ OutOfMemory, InvalidWorker }!*T {
            if (worker >= self.worker_local.len) return error.InvalidWorker;
            return self.acquireImpl(worker);
        }
        fn acquireImpl(self: *Self, worker: ?usize) error{OutOfMemory}!*T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (worker) |index| if (self.worker_local[index]) |local| {
                self.worker_local[index] = null;
                self.in_use[local] = true;
                return &self.values[local];
            };
            if (self.free_len == 0) return error.OutOfMemory;
            self.free_len -= 1;
            const index = self.free_indices[self.free_len];
            self.in_use[index] = true;
            return &self.values[index];
        }
        pub fn acquireBatch(self: *Self, output: []*T) usize {
            var n: usize = 0;
            for (output) |*slot| {
                slot.* = self.acquire() catch break;
                n += 1;
            }
            return n;
        }
        pub fn release(self: *Self, value: *T) !void {
            return self.releaseImpl(value, null);
        }
        /// Returns to the specified worker's local cache when it is empty, otherwise to the shared pool.
        pub fn releaseFor(self: *Self, worker: usize, value: *T) error{ ForeignPointer, DoubleFree, InvalidWorker }!void {
            if (worker >= self.worker_local.len) return error.InvalidWorker;
            return self.releaseImpl(value, worker);
        }
        fn releaseImpl(self: *Self, value: *T, worker: ?usize) error{ ForeignPointer, DoubleFree }!void {
            const begin = @intFromPtr(self.values.ptr);
            const end = begin + self.values.len * @sizeOf(T);
            const address = @intFromPtr(value);
            if (address < begin or address >= end or (address - begin) % @sizeOf(T) != 0) return error.ForeignPointer;
            const index = (address - begin) / @sizeOf(T);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.in_use[index]) return error.DoubleFree;
            self.in_use[index] = false;
            if (worker) |worker_index| if (self.worker_local[worker_index] == null) {
                self.worker_local[worker_index] = index;
                return;
            };
            self.free_indices[self.free_len] = index;
            self.free_len += 1;
        }
        pub fn available(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.free_len;
        }
    };
}
