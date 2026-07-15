const std = @import("std");

pub const ThreadConfig = struct { stack_size: ?usize = null, name: ?[]const u8 = null };
pub const Thread = struct {
    inner: std.Thread,
    /// Joins the thread and releases its OS resources. The handle is consumed.
    pub fn join(self: Thread) void {
        self.inner.join();
    }
    pub fn setName(self: Thread, name: []const u8) !void {
        try self.inner.setName(std.Options.debug_io, name);
    }
};
pub const Id = std.Thread.Id;
pub fn currentId() Id {
    return std.Thread.getCurrentId();
}
pub fn spawn(config: ThreadConfig, comptime function: anytype, args: anytype) !Thread {
    const result = try std.Thread.spawn(.{ .stack_size = config.stack_size orelse std.Thread.SpawnConfig.default_stack_size }, function, args);
    const thread = Thread{ .inner = result };
    if (config.name) |name| thread.setName(name) catch |err| {
        thread.join();
        return err;
    };
    return thread;
}
