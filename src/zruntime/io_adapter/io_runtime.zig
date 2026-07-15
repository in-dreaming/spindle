const std = @import("std");

/// Owns no backend resources. It deliberately exposes only the portable
/// std.Io concurrency operations, keeping backend construction outside this API.
pub const IoRuntime = struct {
    io: std.Io,
    pub fn init(io: std.Io) IoRuntime {
        return .{ .io = io };
    }
    /// Starts work which may complete synchronously on a non-concurrent backend.
    pub fn async(self: IoRuntime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
        return std.Io.async(self.io, function, args);
    }
    /// Starts concurrent work when the configured std.Io implementation supports it.
    pub fn concurrent(self: IoRuntime, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) std.Io.ConcurrentError!std.Io.Future(@typeInfo(@TypeOf(function)).@"fn".return_type.?) {
        return std.Io.concurrent(self.io, function, args);
    }
    pub fn groupAsync(self: IoRuntime, group: *std.Io.Group, function: anytype, args: std.meta.ArgsTuple(@TypeOf(function))) void {
        group.async(self.io, function, args);
    }
    pub fn sleep(self: IoRuntime, duration: std.Io.Duration) std.Io.Cancelable!void {
        return std.Io.sleep(self.io, duration, .awake);
    }
    /// Writes a real file through the configured std.Io implementation.
    pub fn writeFile(self: IoRuntime, path: []const u8, data: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = data });
    }
    /// Reads a real file through the configured std.Io implementation.
    pub fn readFile(self: IoRuntime, path: []const u8, buffer: []u8) ![]u8 {
        return std.Io.Dir.cwd().readFile(self.io, path, buffer);
    }
    pub fn deleteFile(self: IoRuntime, path: []const u8) !void {
        try std.Io.Dir.cwd().deleteFile(self.io, path);
    }
};
