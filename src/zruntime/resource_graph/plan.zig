const std = @import("std");
const access = @import("access.zig");
const key = @import("resource_key.zig");

pub const ResourceNodeId = packed struct(u32) {
    value: u32,
    pub const invalid = ResourceNodeId{ .value = 0 };
};
pub const Hazard = enum(u8) { raw, war, waw, explicit };
pub const Diagnostic = struct { from: ResourceNodeId, to: ResourceNodeId, resource: key.ResourceKey, mode: access.AccessMode, hazard: Hazard };
pub const ResourceTask = struct {
    name: []const u8,
    run_context: ?*anyopaque = null,
    run: ?*const fn (?*anyopaque) void = null,
    /// Optional fallible execution path. A failure stops new downstream submissions.
    run_result: ?*const fn (?*anyopaque) anyerror!void = null,
};
pub const Node = struct { id: ResourceNodeId, task: ResourceTask, dependency_start: usize, dependency_len: usize, dependent_start: usize, dependent_len: usize };
/// Immutable dependency plan. Per-run state belongs to Task 13's scheduler, not this object.
pub const CompiledResourcePlan = struct {
    allocator: std.mem.Allocator,
    nodes: []Node,
    dependencies: []usize,
    dependents: []usize,
    diagnostics: []Diagnostic,
    pub fn deinit(self: *CompiledResourcePlan) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.dependencies);
        self.allocator.free(self.dependents);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }
    pub fn indegree(self: *const CompiledResourcePlan, id: ResourceNodeId) usize {
        const n = self.nodes[id.value - 1];
        return n.dependency_len;
    }
};
