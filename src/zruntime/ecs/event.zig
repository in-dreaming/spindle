const std = @import("std");

/// Synchronous event dispatch. Listeners run on the caller's thread and may not retain the event pointer.
pub fn ImmediateEvent(comptime T: type) type {
    return struct {
        const Self = @This();
        listeners: std.ArrayListUnmanaged(*const fn (*const T) void) = .empty,
        allocator: std.mem.Allocator,
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.listeners.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn subscribe(self: *Self, listener: *const fn (*const T) void) !void {
            try self.listeners.append(self.allocator, listener);
        }
        pub fn emit(self: *const Self, value: *const T) void {
            for (self.listeners.items) |listener| listener(value);
        }
    };
}

/// A worker-local frame-event writer. Events become visible only after FrameEvent.merge.
pub fn FrameEventBuffer(comptime T: type) type {
    return struct {
        events: std.ArrayListUnmanaged(Entry) = .empty,
        allocator: std.mem.Allocator,
        sequence: *std.atomic.Value(u64),
        const Entry = struct { sequence: u64, value: T };
        const Self = @This();
        pub fn init(allocator: std.mem.Allocator, sequence: *std.atomic.Value(u64)) Self {
            return .{ .allocator = allocator, .sequence = sequence };
        }
        pub fn deinit(self: *Self) void {
            self.events.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn emit(self: *Self, value: T) !void {
            try self.events.append(self.allocator, .{ .sequence = self.sequence.fetchAdd(1, .monotonic), .value = value });
        }
    };
}

/// Double-buffered, per-frame event channel. `merge` consumes worker buffers, while `advance` clears the prior frame.
pub fn FrameEvent(comptime T: type) type {
    return struct {
        const Self = @This();
        const Buffer = FrameEventBuffer(T);
        allocator: std.mem.Allocator,
        sequence: std.atomic.Value(u64) = .init(0),
        visible: std.ArrayListUnmanaged(T) = .empty,
        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }
        pub fn deinit(self: *Self) void {
            self.visible.deinit(self.allocator);
            self.* = undefined;
        }
        pub fn buffer(self: *Self) Buffer {
            return Buffer.init(self.allocator, &self.sequence);
        }
        pub fn merge(self: *Self, buffers: []Buffer) !void {
            self.visible.clearRetainingCapacity();
            var entries: std.ArrayListUnmanaged(Buffer.Entry) = .empty;
            defer entries.deinit(self.allocator);
            for (buffers) |*worker_buffer| try entries.appendSlice(self.allocator, worker_buffer.events.items);
            std.mem.sort(Buffer.Entry, entries.items, {}, struct {
                fn less(_: void, a: Buffer.Entry, b: Buffer.Entry) bool {
                    return a.sequence < b.sequence;
                }
            }.less);
            try self.visible.ensureTotalCapacity(self.allocator, entries.items.len);
            for (entries.items) |entry| self.visible.appendAssumeCapacity(entry.value);
        }
        pub fn events(self: *const Self) []const T {
            return self.visible.items;
        }
        pub fn advance(self: *Self) void {
            self.visible.clearRetainingCapacity();
        }
    };
}
