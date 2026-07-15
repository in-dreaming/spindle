const std = @import("std");

/// Child-process fixture for Task 13 recovery tests. It deliberately exits after
/// materializing one durable commit stage; the parent process performs recovery.
pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const stage = args.next() orelse return error.InvalidArguments;
    const directory = args.next() orelse return error.InvalidArguments;
    if (args.next() != null) return error.InvalidArguments;
    const io = init.io;
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    try std.Io.Dir.cwd().createDirPath(io, directory);
    var payload_path: [std.fs.max_path_bytes]u8 = undefined;
    const payload = try std.fmt.bufPrint(&payload_path, "{s}/version-1", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = payload, .data = "child-payload" });
    if (std.mem.eql(u8, stage, "before-record")) return;
    const hash = std.hash.Wyhash.hash(0, "child-payload");
    var record: [96]u8 = undefined;
    const bytes = try std.fmt.bufPrint(&record, "1 {x}\n", .{hash});
    var pending_path: [std.fs.max_path_bytes]u8 = undefined;
    const pending = try std.fmt.bufPrint(&pending_path, "{s}/current.pending", .{directory});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = pending, .data = bytes });
    if (std.mem.eql(u8, stage, "after-record")) return;
    if (!std.mem.eql(u8, stage, "after-pointer")) return error.InvalidArguments;
    var current_path: [std.fs.max_path_bytes]u8 = undefined;
    const current = try std.fmt.bufPrint(&current_path, "{s}/current", .{directory});
    try std.Io.Dir.cwd().rename(pending, std.Io.Dir.cwd(), current, io);
}
