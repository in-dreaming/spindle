const std = @import("std");
const node = @import("node.zig");
const executor = @import("../executor/root.zig");
const Draft = @import("builder.zig").DraftNode;

pub const Node = struct {
    id: node.NodeId,
    target: executor.Executor,
    run: node.TaskFn,
    context: ?*anyopaque,
    dependency_start: usize,
    dependency_len: usize,
    dependent_start: usize,
    dependent_len: usize,
};

/// Immutable, process-local DAG. It owns its compact adjacency arrays.
pub const CompiledLocalTaskGraph = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    dependencies: []usize,
    dependents: []usize,

    pub fn deinit(self: *CompiledLocalTaskGraph) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.dependencies);
        self.allocator.free(self.dependents);
        self.* = undefined;
    }
    pub fn fromBuilder(allocator: std.mem.Allocator, drafts: []const Draft, registry: *executor.ExecutorRegistry) !CompiledLocalTaskGraph {
        const count = drafts.len;
        var targets = try allocator.alloc(executor.Executor, count);
        defer allocator.free(targets);
        var dependency_count: usize = 0;
        for (drafts, 0..) |draft, index| {
            targets[index] = registry.resolve(draft.target) orelse return error.UnboundTarget;
            for (draft.dependencies.items) |id| {
                if (!id.isValid() or id.value > count) return error.InvalidNodeId;
                dependency_count += 1;
            }
        }
        var dependencies = try allocator.alloc(usize, dependency_count);
        errdefer allocator.free(dependencies);
        var indegree = try allocator.alloc(usize, count);
        defer allocator.free(indegree);
        @memset(indegree, 0);
        var dependent_counts = try allocator.alloc(usize, count);
        defer allocator.free(dependent_counts);
        @memset(dependent_counts, 0);
        var offset: usize = 0;
        for (drafts, 0..) |draft, index| {
            for (draft.dependencies.items) |id| {
                const dependency_index = id.value - 1;
                // Deduplicate edges while retaining insertion order.
                var duplicate = false;
                for (dependencies[offset - indegree[index] .. offset]) |existing| if (existing == dependency_index) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) {
                    dependencies[offset] = dependency_index;
                    offset += 1;
                    indegree[index] += 1;
                    dependent_counts[dependency_index] += 1;
                }
            }
        }
        const compact_dependencies = try allocator.realloc(dependencies, offset);
        dependencies = compact_dependencies;
        var dependent_offsets = try allocator.alloc(usize, count + 1);
        defer allocator.free(dependent_offsets);
        dependent_offsets[0] = 0;
        for (dependent_counts, 0..) |value, i| dependent_offsets[i + 1] = dependent_offsets[i] + value;
        var dependents = try allocator.alloc(usize, offset);
        errdefer allocator.free(dependents);
        var positions = try allocator.dupe(usize, dependent_offsets[0..count]);
        defer allocator.free(positions);
        var dependency_offsets = try allocator.alloc(usize, count + 1);
        defer allocator.free(dependency_offsets);
        dependency_offsets[0] = 0;
        for (drafts, 0..) |draft, i| dependency_offsets[i + 1] = dependency_offsets[i] + draft.dependencies.items.len;
        // Recompute compact starts because duplicate edges changed lengths.
        var cursor: usize = 0;
        for (drafts, 0..) |draft, i| {
            dependency_offsets[i] = cursor;
            var seen: usize = 0;
            for (draft.dependencies.items) |id| {
                const dep = id.value - 1;
                var duplicate = false;
                for (dependencies[cursor .. cursor + seen]) |existing| if (existing == dep) {
                    duplicate = true;
                    break;
                };
                if (!duplicate) {
                    dependencies[cursor + seen] = dep;
                    seen += 1;
                }
            }
            for (dependencies[cursor .. cursor + seen]) |dep| {
                dependents[positions[dep]] = i;
                positions[dep] += 1;
            }
            cursor += seen;
        }
        dependency_offsets[count] = cursor;
        // Kahn validation without modifying the immutable adjacency data.
        var work = try allocator.dupe(usize, indegree);
        defer allocator.free(work);
        var queue = std.ArrayListUnmanaged(usize).empty;
        defer queue.deinit(allocator);
        for (work, 0..) |degree, i| if (degree == 0) try queue.append(allocator, i);
        var visited: usize = 0;
        var head: usize = 0;
        while (head < queue.items.len) {
            const current = queue.items[head];
            head += 1;
            visited += 1;
            for (dependents[dependent_offsets[current]..dependent_offsets[current + 1]]) |next| {
                work[next] -= 1;
                if (work[next] == 0) try queue.append(allocator, next);
            }
        }
        if (visited != count) return error.CycleDetected;
        var nodes = try allocator.alloc(Node, count);
        errdefer allocator.free(nodes);
        for (drafts, 0..) |draft, i| nodes[i] = .{ .id = .{ .value = @intCast(i + 1) }, .target = targets[i], .run = draft.run, .context = draft.context, .dependency_start = dependency_offsets[i], .dependency_len = dependency_offsets[i + 1] - dependency_offsets[i], .dependent_start = dependent_offsets[i], .dependent_len = dependent_offsets[i + 1] - dependent_offsets[i] };
        return .{ .allocator = allocator, .nodes = nodes, .dependencies = dependencies, .dependents = dependents };
    }
};
