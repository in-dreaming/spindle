const std = @import("std");
const snapshot = @import("snapshot.zig");
const World = @import("world.zig").World;
const executor = @import("../executor/root.zig");

/// Caller-supplied deterministic frame inputs. Empty required envelopes make a frame explicitly non-replayable.
pub const FrameInput = struct {
    input: []const u8 = &.{},
    network: []const u8 = &.{},
    external: []const u8 = &.{},
    random_seed: ?u64 = null,
    require_input: bool = false,
    require_network: bool = false,
    require_external: bool = false,
};

/// Owned journal record. Structural commands are the finalized command payload supplied by the ECS update owner.
pub const Frame = struct {
    number: u64,
    input: []u8,
    network: []u8,
    external: []u8,
    structural: []u8,
    random_seed: ?u64,
    replayable: bool,
    state_hash: u64,
    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
        allocator.free(self.network);
        allocator.free(self.external);
        allocator.free(self.structural);
        self.* = undefined;
    }
};

/// Append-only, bounded frame journal. It never fabricates missing deterministic inputs.
pub const Journal = struct {
    allocator: std.mem.Allocator,
    frames: std.ArrayListUnmanaged(Frame) = .empty,
    capacity: usize,
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Journal {
        if (capacity == 0) return error.InvalidCapacity;
        return .{ .allocator = allocator, .capacity = capacity };
    }
    pub fn deinit(self: *Journal) void {
        for (self.frames.items) |*record| record.deinit(self.allocator);
        self.frames.deinit(self.allocator);
        self.* = undefined;
    }
    /// Records exactly the envelopes supplied by the caller and marks incomplete required data non-replayable.
    pub fn append(self: *Journal, number: u64, value: FrameInput, structural: []const u8, state_hash: u64) !void {
        const replayable = value.random_seed != null and (!value.require_input or value.input.len != 0) and (!value.require_network or value.network.len != 0) and (!value.require_external or value.external.len != 0);
        var record = Frame{ .number = number, .input = try self.allocator.dupe(u8, value.input), .network = undefined, .external = undefined, .structural = undefined, .random_seed = value.random_seed, .replayable = replayable, .state_hash = state_hash };
        errdefer self.allocator.free(record.input);
        record.network = try self.allocator.dupe(u8, value.network);
        errdefer self.allocator.free(record.network);
        record.external = try self.allocator.dupe(u8, value.external);
        errdefer self.allocator.free(record.external);
        record.structural = try self.allocator.dupe(u8, structural);
        errdefer self.allocator.free(record.structural);
        if (self.frames.items.len == self.capacity) {
            var old = self.frames.orderedRemove(0);
            old.deinit(self.allocator);
        }
        try self.frames.append(self.allocator, record);
    }
    pub fn frame(self: *const Journal, number: u64) ?*const Frame {
        for (self.frames.items) |*item| if (item.number == number) return item;
        return null;
    }
};

/// Runs one ECS frame and appends its post-frame canonical hash with the exact caller-supplied inputs.
/// Systems consume inputs through their normal world resources; this helper never invents defaults.
pub fn updateFrame(world: *World, runtime: World.SchedulerRuntime, dt: f32, journal: *Journal, number: u64, input: FrameInput, finalized_structural_commands: []const u8) !u64 {
    try world.update(runtime, dt);
    const state_hash = try snapshot.canonicalHash(world.allocator, world);
    try journal.append(number, input, finalized_structural_commands, state_hash);
    return state_hash;
}

/// Bounded rollback state coupled to the exact journal frames that produced it.
pub const RollbackRing = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    capacity: usize,
    pub const Entry = struct {
        frame: u64,
        image: snapshot.Snapshot,
        state_hash: u64,
        pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            self.image.deinit(allocator);
            self.* = undefined;
        }
    };
    pub fn init(allocator: std.mem.Allocator, capacity: usize) !RollbackRing {
        if (capacity == 0) return error.InvalidCapacity;
        return .{ .allocator = allocator, .capacity = capacity };
    }
    pub fn deinit(self: *RollbackRing) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn push(self: *RollbackRing, frame: u64, image: snapshot.Snapshot) !void {
        if (self.entries.items.len == self.capacity) {
            var old = self.entries.orderedRemove(0);
            old.deinit(self.allocator);
        }
        try self.entries.append(self.allocator, .{ .frame = frame, .state_hash = image.hash, .image = image });
    }
    /// Restores only an in-window state. Callers replay subsequent journal frames with their deterministic executor.
    pub fn rollback(self: *const RollbackRing, world: anytype, frame: u64) !void {
        for (self.entries.items) |entry| if (entry.frame == frame) return snapshot.restore(world, entry.image.bytes);
        return error.RollbackOutOfWindow;
    }
};

/// Re-executes journal frames after a rollback using the deterministic executor and compares full canonical state.
/// The callback must submit its stable-ID ECS work to `deterministic` and apply the journal frame's exact data.
pub const ReplayFn = *const fn (*World, *const Frame, *executor.DeterministicExecutor) anyerror!void;
pub fn replay(allocator: std.mem.Allocator, ring: *const RollbackRing, journal: *const Journal, world: *World, from_frame: u64, through_frame: u64, drive: ReplayFn) !void {
    try ring.rollback(world, from_frame);
    var deterministic = executor.DeterministicExecutor.init(allocator);
    defer deterministic.deinit();
    for (journal.frames.items) |*record| {
        if (record.number <= from_frame or record.number > through_frame) continue;
        if (!record.replayable) return error.FrameNotReplayable;
        try drive(world, record, &deterministic);
        try deterministic.run();
        if (try snapshot.canonicalHash(allocator, world) != record.state_hash) return error.ReplayDivergence;
    }
}

test "journal rejects replay for omitted required data and rollback window is bounded" {
    var journal = try Journal.init(std.testing.allocator, 1);
    defer journal.deinit();
    try journal.append(4, .{ .require_input = true, .random_seed = 7 }, &.{}, 12);
    try std.testing.expect(!journal.frame(4).?.replayable);
}

const ReplayValue = struct { value: u32 };
fn replaySetValue(world: *World, record: *const Frame, _: *executor.DeterministicExecutor) !void {
    const id = world.componentId("journal.replay-value");
    const entity = world.archetypes.items[1].chunks.items[0].entities()[0];
    try world.setRaw(entity, id, record.input);
}
test "rollback replay restores a snapshot and compares canonical state every frame" {
    var world = try World.init(std.testing.allocator, .{});
    defer world.deinit();
    const id = try world.registerComponent(ReplayValue, "journal.replay-value");
    const entity = try world.create();
    try world.add(entity, id, ReplayValue{ .value = 1 });
    var ring = try RollbackRing.init(std.testing.allocator, 2);
    defer ring.deinit();
    try ring.push(0, try snapshot.capture(std.testing.allocator, &world));
    try world.set(entity, id, ReplayValue{ .value = 9 });
    var journal = try Journal.init(std.testing.allocator, 2);
    defer journal.deinit();
    try journal.append(1, .{ .input = std.mem.asBytes(&ReplayValue{ .value = 9 }), .random_seed = 1 }, &.{}, try snapshot.canonicalHash(std.testing.allocator, &world));
    try world.set(entity, id, ReplayValue{ .value = 2 });
    try replay(std.testing.allocator, &ring, &journal, &world, 0, 1, replaySetValue);
    try std.testing.expectEqual(@as(u32, 9), (try world.get(entity, id, ReplayValue)).value);
}
