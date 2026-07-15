const std = @import("std");
const spindle = @import("spindle");
const login = @import("login_workflow");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) return error.InvalidArguments;
    const stage = args[1];
    const path = args[2];
    var clock_source = spindle.core.clock.VirtualClock.init(0, 1000);
    var store = try spindle.workflow.sqlite.Store.init(init.gpa, path, clock_source.clock());
    defer store.deinit();
    var registry = spindle.workflow.Registry.init(init.gpa);
    defer registry.deinit();
    try registry.register(login.definition);
    registry.freeze();
    if (std.mem.eql(u8, stage, "after-commit")) {
        const worker = spindle.workflow.sqlite_worker.Worker{ .allocator = init.gpa, .store = &store, .registry = &registry, .tenant = "crash", .namespace = "test" };
        if (!try worker.runOne()) return error.MissingTask;
    } else if (std.mem.eql(u8, stage, "after-claim") or std.mem.eql(u8, stage, "before-commit")) {
        if (try store.claimWorkflowTask("crash", "test") == null) return error.MissingTask;
    } else return error.InvalidArguments;
    var output_buffer: [16]u8 = undefined;
    var output_writer = std.Io.File.stdout().writer(init.io, &output_buffer);
    try output_writer.interface.writeAll("READY\n");
    try output_writer.interface.flush();
    while (true) std.Thread.yield() catch {};
}
