const std = @import("std");
const access = @import("access.zig");
const key = @import("resource_key.zig");
const plan = @import("plan.zig");

const Draft = struct { task: plan.ResourceTask, accesses: std.ArrayListUnmanaged(access.ResourceAccess) = .empty, explicit: std.ArrayListUnmanaged(plan.ResourceNodeId) = .empty };
const Edge = struct { from: usize, to: usize, resource: key.ResourceKey, mode: access.AccessMode, hazard: plan.Hazard };
const Frontier = struct { resource: key.ResourceKey, range: @import("resource_range.zig").ResourceRange, writer: ?usize = null, readers: std.ArrayListUnmanaged(usize) = .empty };
const Lifecycle = struct { resource: key.ResourceKey, state: @import("version.zig").State };

/// Mutable resource-graph builder. It has no Local Task Graph node dependency.
pub const ResourceTaskGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Draft) = .empty,
    pub fn init(allocator: std.mem.Allocator) ResourceTaskGraph {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *ResourceTaskGraph) void {
        for (self.nodes.items) |*n| {
            n.accesses.deinit(self.allocator);
            n.explicit.deinit(self.allocator);
        }
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn addTask(self: *ResourceTaskGraph, task: plan.ResourceTask) !plan.ResourceNodeId {
        if (self.nodes.items.len >= std.math.maxInt(u32) - 1) return error.TooManyNodes;
        try self.nodes.append(self.allocator, .{ .task = task });
        return .{ .value = @intCast(self.nodes.items.len) };
    }
    pub fn addAccess(self: *ResourceTaskGraph, id: plan.ResourceNodeId, declaration: access.ResourceAccess) !void {
        try declaration.validate();
        try self.node(id).accesses.append(self.allocator, declaration);
    }
    pub fn dependsOn(self: *ResourceTaskGraph, dependent: plan.ResourceNodeId, dependency: plan.ResourceNodeId) !void {
        _ = try self.node(dependency);
        try self.node(dependent).explicit.append(self.allocator, dependency);
    }
    fn node(self: *ResourceTaskGraph, id: plan.ResourceNodeId) !*Draft {
        if (id.value == 0 or id.value > self.nodes.items.len) return error.InvalidNodeId;
        return &self.nodes.items[id.value - 1];
    }
    /// Compiles RAW/WAR/WAW and explicit edges into a compact immutable DAG.
    pub fn compile(self: *const ResourceTaskGraph, allocator: std.mem.Allocator) !plan.CompiledResourcePlan {
        var frontiers: std.ArrayListUnmanaged(Frontier) = .empty;
        defer {
            for (frontiers.items) |*f| f.readers.deinit(allocator);
            frontiers.deinit(allocator);
        }
        var edges: std.ArrayListUnmanaged(Edge) = .empty;
        defer edges.deinit(allocator);
        var lifecycles: std.ArrayListUnmanaged(Lifecycle) = .empty;
        defer lifecycles.deinit(allocator);
        for (self.nodes.items, 0..) |draft, index| {
            for (draft.explicit.items) |id| {
                if (id.value == 0 or id.value > self.nodes.items.len) return error.InvalidNodeId;
                try addEdge(&edges, allocator, id.value - 1, index, .{ .kind = .custom, .namespace = .zero, .name = "explicit", .cached_hash = 0 }, .read, .explicit);
            }
            for (draft.accesses.items) |declaration| {
                try validateLifecycle(&lifecycles, allocator, declaration);
                var matches: std.ArrayListUnmanaged(usize) = .empty;
                defer matches.deinit(allocator);
                for (frontiers.items, 0..) |f, fi| {
                    if (conflicts(f.resource, f.range, declaration.key, declaration.range)) try matches.append(allocator, fi);
                }
                if (matches.items.len == 0) {
                    try frontiers.append(allocator, .{ .resource = declaration.key, .range = declaration.range });
                    try matches.append(allocator, frontiers.items.len - 1);
                }
                for (matches.items) |fi| {
                    const f = &frontiers.items[fi];
                    if (declaration.mode == .read) {
                        if (f.writer) |writer| try addEdge(&edges, allocator, writer, index, declaration.key, declaration.mode, .raw);
                        try f.readers.append(allocator, index);
                    } else {
                        if (f.writer) |writer| try addEdge(&edges, allocator, writer, index, declaration.key, declaration.mode, .waw);
                        for (f.readers.items) |reader| try addEdge(&edges, allocator, reader, index, declaration.key, declaration.mode, .war);
                        f.readers.clearRetainingCapacity();
                        f.writer = index;
                    }
                }
            }
        }
        return buildPlan(allocator, self.nodes.items, edges.items);
    }
};
fn validateLifecycle(lifecycles: *std.ArrayListUnmanaged(Lifecycle), allocator: std.mem.Allocator, declaration: access.ResourceAccess) !void {
    var found: ?*Lifecycle = null;
    for (lifecycles.items) |*entry| if (entry.resource.eql(declaration.key)) {
        found = entry;
        break;
    };
    if (found == null) {
        const initial: @import("version.zig").State = if (declaration.mode == .create) .tombstone else .present;
        try lifecycles.append(allocator, .{ .resource = declaration.key, .state = initial });
        found = &lifecycles.items[lifecycles.items.len - 1];
    }
    const entry = found.?;
    switch (declaration.mode) {
        .create => {
            if (entry.state == .present) return error.InvalidLifecycle;
            entry.state = .present;
        },
        .delete => {
            if (entry.state == .tombstone) return error.InvalidLifecycle;
            entry.state = .tombstone;
        },
        .read, .write => if (entry.state == .tombstone) return error.InvalidLifecycle,
    }
}
fn addEdge(edges: *std.ArrayListUnmanaged(Edge), allocator: std.mem.Allocator, from: usize, to: usize, resource: key.ResourceKey, mode: access.AccessMode, hazard: plan.Hazard) !void {
    if (from == to) return error.CycleDetected;
    for (edges.items) |e| if (e.from == from and e.to == to) return;
    try edges.append(allocator, .{ .from = from, .to = to, .resource = resource, .mode = mode, .hazard = hazard });
}

/// File whole-resource accesses form barriers around all page frontiers for the same file.
fn conflicts(a_key: key.ResourceKey, a_range: @import("resource_range.zig").ResourceRange, b_key: key.ResourceKey, b_range: @import("resource_range.zig").ResourceRange) bool {
    if (a_key.file) |a_file| {
        if (b_key.file) |b_file| {
            if (!a_file.eql(b_file)) return false;
            if (a_key.kind == .file or b_key.kind == .file) return true;
            return a_key.page == b_key.page and a_range.overlaps(b_range);
        }
    }
    return a_key.eql(b_key) and a_range.overlaps(b_range);
}
fn buildPlan(allocator: std.mem.Allocator, drafts: []const Draft, edges: []const Edge) !plan.CompiledResourcePlan {
    const n = drafts.len;
    var counts = try allocator.alloc(usize, n);
    defer allocator.free(counts);
    @memset(counts, 0);
    var dcounts = try allocator.alloc(usize, n);
    defer allocator.free(dcounts);
    @memset(dcounts, 0);
    for (edges) |e| {
        counts[e.to] += 1;
        dcounts[e.from] += 1;
    }
    var starts = try allocator.alloc(usize, n + 1);
    defer allocator.free(starts);
    var dstarts = try allocator.alloc(usize, n + 1);
    defer allocator.free(dstarts);
    starts[0] = 0;
    dstarts[0] = 0;
    for (0..n) |i| {
        starts[i + 1] = starts[i] + counts[i];
        dstarts[i + 1] = dstarts[i] + dcounts[i];
    }
    var deps = try allocator.alloc(usize, edges.len);
    errdefer allocator.free(deps);
    var dependents = try allocator.alloc(usize, edges.len);
    errdefer allocator.free(dependents);
    var pos = try allocator.dupe(usize, starts[0..n]);
    defer allocator.free(pos);
    var dpos = try allocator.dupe(usize, dstarts[0..n]);
    defer allocator.free(dpos);
    for (edges) |e| {
        deps[pos[e.to]] = e.from;
        pos[e.to] += 1;
        dependents[dpos[e.from]] = e.to;
        dpos[e.from] += 1;
    }
    var work = try allocator.dupe(usize, counts);
    defer allocator.free(work);
    var queue: std.ArrayListUnmanaged(usize) = .empty;
    defer queue.deinit(allocator);
    for (work, 0..) |v, i| if (v == 0) try queue.append(allocator, i);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) for (dependents[dstarts[queue.items[head]]..dstarts[queue.items[head] + 1]]) |next| {
        work[next] -= 1;
        if (work[next] == 0) try queue.append(allocator, next);
    };
    if (queue.items.len != n) return error.CycleDetected;
    var nodes = try allocator.alloc(plan.Node, n);
    errdefer allocator.free(nodes);
    for (drafts, 0..) |d, i| nodes[i] = .{ .id = .{ .value = @intCast(i + 1) }, .task = d.task, .dependency_start = starts[i], .dependency_len = counts[i], .dependent_start = dstarts[i], .dependent_len = dcounts[i] };
    const diagnostics = try allocator.alloc(plan.Diagnostic, edges.len);
    errdefer allocator.free(diagnostics);
    for (edges, 0..) |e, i| diagnostics[i] = .{ .from = .{ .value = @intCast(e.from + 1) }, .to = .{ .value = @intCast(e.to + 1) }, .resource = e.resource, .mode = e.mode, .hazard = e.hazard };
    return .{ .allocator = allocator, .nodes = nodes, .dependencies = deps, .dependents = dependents, .diagnostics = diagnostics };
}

test "resource graph produces RAW WAR and WAW diagnostics" {
    const ns = @import("../core/root.zig").StableId.zero;
    const resource = key.ResourceKey.named(.memory_buffer, ns, "buffer");
    var graph = ResourceTaskGraph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addTask(.{ .name = "write" });
    const b = try graph.addTask(.{ .name = "read" });
    const c = try graph.addTask(.{ .name = "write again" });
    try graph.addAccess(a, .{ .key = resource, .mode = .write });
    try graph.addAccess(b, .{ .key = resource, .mode = .read });
    try graph.addAccess(c, .{ .key = resource, .mode = .write });
    var compiled = try graph.compile(std.testing.allocator);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 3), compiled.diagnostics.len);
    try std.testing.expectEqual(plan.Hazard.raw, compiled.diagnostics[0].hazard);
    try std.testing.expectEqual(plan.Hazard.waw, compiled.diagnostics[1].hazard);
    try std.testing.expectEqual(plan.Hazard.war, compiled.diagnostics[2].hazard);
}

test "page frontiers remain independent but whole accesses are barriers" {
    const ns = @import("../core/root.zig").StableId.zero;
    const file = key.FileIdentity.init(ns, "assets/a.bin");
    var graph = ResourceTaskGraph.init(std.testing.allocator);
    defer graph.deinit();
    const page_one = try graph.addTask(.{ .name = "page one" });
    const page_two = try graph.addTask(.{ .name = "page two" });
    const whole = try graph.addTask(.{ .name = "whole" });
    try graph.addAccess(page_one, .{ .key = key.ResourceKey.pageKey(file, 1), .mode = .write });
    try graph.addAccess(page_two, .{ .key = key.ResourceKey.pageKey(file, 2), .mode = .write });
    try graph.addAccess(whole, .{ .key = key.ResourceKey.fileKey(file), .mode = .read });
    var compiled = try graph.compile(std.testing.allocator);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(usize, 2), compiled.indegree(whole));
}

test "create lifecycle and unsupported range are rejected" {
    const ns = @import("../core/root.zig").StableId.zero;
    const resource = key.ResourceKey.named(.custom, ns, "new-resource");
    var graph = ResourceTaskGraph.init(std.testing.allocator);
    defer graph.deinit();
    const create = try graph.addTask(.{ .name = "create" });
    const duplicate = try graph.addTask(.{ .name = "duplicate" });
    try graph.addAccess(create, .{ .key = resource, .mode = .create, .version = .must_not_exist });
    try graph.addAccess(duplicate, .{ .key = resource, .mode = .create, .version = .must_not_exist });
    try std.testing.expectError(error.InvalidLifecycle, graph.compile(std.testing.allocator));
    var ranges = ResourceTaskGraph.init(std.testing.allocator);
    defer ranges.deinit();
    const node = try ranges.addTask(.{ .name = "range" });
    try std.testing.expectError(error.UnsupportedRange, ranges.addAccess(node, .{ .key = resource, .range = .{ .byte = .{ .start = 0, .end = 4 } }, .mode = .read }));
}
