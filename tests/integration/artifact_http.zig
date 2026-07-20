const std = @import("std");
const spindle = @import("spindle");
const build_options = @import("build_options");

test "artifact store uses a real local HTTP server process" {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{ .environ = .{ .block = .global } });
    defer threaded.deinit();
    const process_io = threaded.io();
    const io = process_io;
    const directory = "spindle-task14-http";
    std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, directory) catch {};
    var child = try std.process.spawn(process_io, .{ .argv = &.{ "powershell", "-ExecutionPolicy", "Bypass", "-File", build_options.server_script, directory, "19007" }, .stdin = .ignore, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
    defer child.kill(process_io);
    var ready_buffer: [16]u8 = undefined;
    var ready_reader = child.stdout.?.readerStreaming(process_io, &ready_buffer);
    const ready_line = ready_reader.interface.takeArray(7) catch |err| {
        var stderr_reader = child.stderr.?.readerStreaming(process_io, &.{});
        const stderr = stderr_reader.interface.allocRemaining(std.heap.smp_allocator, .limited(4096)) catch return err;
        defer std.heap.smp_allocator.free(stderr);
        std.debug.print("artifact fixture stderr: {s}\n", .{stderr});
        return err;
    };
    try std.testing.expectEqualStrings("READY\r\n", ready_line[0..]);
    var store = spindle.resource_graph.cache.ArtifactStore.init(std.testing.allocator, io, "http://127.0.0.1:19007");
    const data = "real-http-artifact";
    var key: spindle.resource_graph.Fingerprint = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &key, .{});
    try std.testing.expect(!(try store.head(key, null)));
    try store.put(key, data, null);
    try std.testing.expect(try store.head(key, null));
    const artifact = (try store.get(key, null)).?;
    defer std.testing.allocator.free(artifact.bytes);
    try std.testing.expectEqualStrings(data, artifact.bytes);
}
