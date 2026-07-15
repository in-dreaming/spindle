const std = @import("std");
const schema = @import("schema.zig");

pub const MigrationFn = *const fn (context: *anyopaque, allocator: std.mem.Allocator, input: []const u8) anyerror![]u8;
pub const Migration = struct { from_version: u32, context: *anyopaque, apply: MigrationFn };

/// Registry errors are raised before any ownership transfer or destination mutation.
pub const Error = error{ Frozen, DuplicateId, DuplicateName, VersionRegression, MigrationGap, UnknownSchema, UnknownVersion, PayloadTooLarge };

/// Mutable during setup and immutable after `freeze`. Frozen lookups are lock-free.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    frozen: bool = false,

    const Entry = struct { meta: schema.SchemaMeta, migration: ?Migration };

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Registers one schema version. Setup calls are intentionally not thread-safe.
    pub fn register(self: *Registry, meta: schema.SchemaMeta, migration: ?Migration) (Error || std.mem.Allocator.Error)!void {
        if (self.frozen) return error.Frozen;
        for (self.entries.items) |entry| {
            if (entry.meta.key.id == meta.key.id and entry.meta.key.version == meta.key.version) return error.DuplicateId;
            if (std.mem.eql(u8, entry.meta.stable_name, meta.stable_name) and entry.meta.key.id != meta.key.id) return error.DuplicateName;
            if (entry.meta.key.id == meta.key.id and entry.meta.key.version > meta.key.version) return error.VersionRegression;
        }
        if (migration) |step| {
            if (step.from_version + 1 != meta.key.version) return error.MigrationGap;
            if (self.find(meta.key.id, step.from_version) == null) return error.MigrationGap;
        } else if (self.findLatest(meta.key.id)) |previous| {
            if (previous.meta.key.version + 1 == meta.key.version) return error.MigrationGap;
        }
        try self.entries.append(self.allocator, .{ .meta = meta, .migration = migration });
    }

    /// Makes the registry immutable. The owner must not call `deinit` until all readers stop.
    pub fn freeze(self: *Registry) void {
        self.frozen = true;
    }

    /// Looks up a registered version. This is safe for concurrent use after `freeze`.
    pub fn find(self: *const Registry, id: u64, version: u32) ?schema.SchemaMeta {
        for (self.entries.items) |entry| if (entry.meta.key.id == id and entry.meta.key.version == version) return entry.meta;
        return null;
    }

    fn findLatest(self: *const Registry, id: u64) ?Entry {
        var result: ?Entry = null;
        for (self.entries.items) |entry| {
            if (entry.meta.key.id == id and (result == null or entry.meta.key.version > result.?.meta.key.version)) {
                result = entry;
            }
        }
        return result;
    }

    /// Migrates one version at a time. On error, `destination` is untouched.
    pub fn migrate(self: *const Registry, id: u64, from_version: u32, to_version: u32, input: []const u8, destination: *std.ArrayListUnmanaged(u8), max_payload_len: usize) (Error || std.mem.Allocator.Error || anyerror)!void {
        if (input.len > max_payload_len) return error.PayloadTooLarge;
        if (from_version > to_version) return error.VersionRegression;
        if (self.findEntry(id, from_version) == null) {
            if (self.findLatest(id) == null) return error.UnknownSchema;
            return error.UnknownVersion;
        }
        var current = input;
        var owned: ?[]u8 = null;
        defer if (owned) |buffer| self.allocator.free(buffer);
        var version = from_version;
        while (version < to_version) : (version += 1) {
            const entry = self.findEntry(id, version + 1) orelse return error.UnknownVersion;
            const step = entry.migration orelse return error.MigrationGap;
            const next = try step.apply(step.context, self.allocator, current);
            if (next.len > max_payload_len) {
                self.allocator.free(next);
                return error.PayloadTooLarge;
            }
            if (owned) |buffer| self.allocator.free(buffer);
            owned = next;
            current = next;
        }
        try destination.appendSlice(self.allocator, current);
    }

    fn findEntry(self: *const Registry, id: u64, version: u32) ?Entry {
        for (self.entries.items) |entry| if (entry.meta.key.id == id and entry.meta.key.version == version) return entry;
        return null;
    }
};

fn appendBang(_: *anyopaque, allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const output = try allocator.alloc(u8, input.len + 1);
    @memcpy(output[0..input.len], input);
    output[input.len] = '!';
    return output;
}

test "registry migrates sequentially without mutating destination on lookup failure" {
    var registry = Registry.init(std.testing.allocator);
    defer registry.deinit();
    var context: u8 = 0;
    try registry.register(.{ .key = .{ .id = 1, .version = 1 }, .stable_name = "test.value" }, null);
    try registry.register(.{ .key = .{ .id = 1, .version = 2 }, .stable_name = "test.value" }, .{ .from_version = 1, .context = &context, .apply = appendBang });
    var destination: std.ArrayListUnmanaged(u8) = .empty;
    defer destination.deinit(std.testing.allocator);
    try registry.migrate(1, 1, 2, "value", &destination, 16);
    try std.testing.expectEqualStrings("value!", destination.items);
    try std.testing.expectError(error.UnknownVersion, registry.migrate(1, 3, 3, "x", &destination, 16));
    try std.testing.expectEqualStrings("value!", destination.items);
}
