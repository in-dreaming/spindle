const std = @import("std");
const node = @import("node.zig");
const executor = @import("../executor/root.zig");
const compiled = @import("compiled_graph.zig");

const Draft = struct {
    target: executor.ExecutorId,
    run: node.TaskFn,
    context: ?*anyopaque,
    dependencies: std.ArrayListUnmanaged(node.NodeId) = .empty,
};

/// Mutable graph builder. It owns draft dependency storage until `compile` or `deinit`.
pub const LocalTaskGraph = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(Draft) = .empty,

    pub fn init(allocator: std.mem.Allocator) LocalTaskGraph {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *LocalTaskGraph) void {
        for (self.nodes.items) |*draft| draft.dependencies.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }
    /// Adds a node with an explicit registered executor target.
    pub fn addTask(self: *LocalTaskGraph, target: executor.ExecutorId, context: ?*anyopaque, run: node.TaskFn) !node.NodeId {
        if (self.nodes.items.len >= std.math.maxInt(u32) - 1) return error.TooManyNodes;
        try self.nodes.append(self.allocator, .{ .target = target, .context = context, .run = run });
        return .{ .value = @intCast(self.nodes.items.len) };
    }
    /// Makes `dependent` wait for successful completion of `dependency`.
    pub fn dependsOn(self: *LocalTaskGraph, dependent: node.NodeId, dependency: node.NodeId) !void {
        const dependent_index = try self.indexOf(dependent);
        _ = try self.indexOf(dependency);
        try self.nodes.items[dependent_index].dependencies.append(self.allocator, dependency);
    }
    /// Validates and freezes this builder into an independently owned immutable graph.
    pub fn compile(self: *const LocalTaskGraph, allocator: std.mem.Allocator, registry: *executor.ExecutorRegistry) !compiled.CompiledLocalTaskGraph {
        return compiled.CompiledLocalTaskGraph.fromBuilder(allocator, self.nodes.items, registry);
    }
    fn indexOf(self: *const LocalTaskGraph, id: node.NodeId) !usize {
        if (!id.isValid() or id.value > self.nodes.items.len) return error.InvalidNodeId;
        return id.value - 1;
    }
};

pub const DraftNode = Draft;
