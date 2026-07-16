const std = @import("std");
const resource_graph = @import("../resource_graph/root.zig");
const archive = @import("archive.zig");

/// HTTP archive facade. Locations are canonical lowercase SHA-256 CAS keys.
pub const ArtifactStore = struct {
    remote: resource_graph.cache.ArtifactStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, endpoint: []const u8) ArtifactStore {
        return .{ .remote = resource_graph.cache.ArtifactStore.init(allocator, io, endpoint) };
    }
    pub fn storage(self: *ArtifactStore) archive.Storage {
        return .{ .context = self, .put_fn = erasedPut, .get_fn = erasedGet };
    }
    pub fn put(self: ArtifactStore, location: []const u8, bytes: []const u8) !void {
        const key = try parseLocation(location);
        try self.remote.put(key, bytes, null);
    }
    pub fn get(self: ArtifactStore, allocator: std.mem.Allocator, location: []const u8) ![]u8 {
        const key = try parseLocation(location);
        const artifact = (try self.remote.get(key, null)) orelse return error.NotFound;
        if (allocator.ptr == self.remote.allocator.ptr and allocator.vtable == self.remote.allocator.vtable) return artifact.bytes;
        defer self.remote.allocator.free(artifact.bytes);
        return allocator.dupe(u8, artifact.bytes);
    }
    fn parseLocation(location: []const u8) !resource_graph.cache.Fingerprint {
        if (location.len != 64) return error.InvalidLocation;
        var result: resource_graph.cache.Fingerprint = undefined;
        for (&result, 0..) |*byte, index| {
            const high = try std.fmt.charToDigit(location[index * 2], 16);
            const low = try std.fmt.charToDigit(location[index * 2 + 1], 16);
            byte.* = @intCast(high * 16 + low);
        }
        return result;
    }
    fn erasedPut(context: *anyopaque, location: []const u8, bytes: []const u8) anyerror!void {
        const self: *ArtifactStore = @ptrCast(@alignCast(context));
        try self.put(location, bytes);
    }
    fn erasedGet(context: *anyopaque, allocator: std.mem.Allocator, location: []const u8) anyerror![]u8 {
        const self: *ArtifactStore = @ptrCast(@alignCast(context));
        return self.get(allocator, location);
    }
};
