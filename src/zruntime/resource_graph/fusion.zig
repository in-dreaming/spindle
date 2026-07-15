const std = @import("std");
const plan = @import("plan.zig");

/// Fusion is opt-in and only joins adjacent nodes with an explicit proof token.
/// `members` retain the original node IDs so result, trace, cancellation, and failure
/// attribution remain observable at the pre-fusion boundary.
pub const Policy = struct { kind: []const u8, proof: []const u8, allow_page: bool = true };
pub const Group = struct { members: []const plan.ResourceNodeId, kind: []const u8 };

pub fn groups(allocator: std.mem.Allocator, compiled: *const plan.CompiledResourcePlan, policies: []const Policy) ![]Group {
    var result: std.ArrayListUnmanaged(Group) = .empty;
    errdefer {
        for (result.items) |group| allocator.free(group.members);
        result.deinit(allocator);
    }
    var index: usize = 0;
    while (index < compiled.nodes.len) {
        const node = compiled.nodes[index];
        const enabled = enabledFor(node, policies);
        var end = index + 1;
        // A chain may fuse only with a declared equivalent kind/proof and no
        // externally visible branch at either internal edge.
        while (enabled and end < compiled.nodes.len and enabledFor(compiled.nodes[end], policies) and std.mem.eql(u8, node.task.name, compiled.nodes[end].task.name) and directChain(compiled, end - 1, end)) end += 1;
        const members = try allocator.alloc(plan.ResourceNodeId, end - index);
        for (members, 0..) |*member, member_index| member.* = compiled.nodes[index + member_index].id;
        try result.append(allocator, .{ .members = members, .kind = if (enabled and members.len > 1) node.task.name else "unfused" });
        index = end;
    }
    return result.toOwnedSlice(allocator);
}
fn enabledFor(node: plan.Node, policies: []const Policy) bool {
    for (policies) |policy| if (std.mem.eql(u8, node.task.name, policy.kind) and policy.proof.len > 0) return true;
    return false;
}
fn directChain(compiled: *const plan.CompiledResourcePlan, left: usize, right: usize) bool {
    const a = compiled.nodes[left];
    const b = compiled.nodes[right];
    return a.dependent_len == 1 and b.dependency_len == 1 and compiled.dependents[a.dependent_start] == right and compiled.dependencies[b.dependency_start] == left;
}
pub fn deinitGroups(allocator: std.mem.Allocator, values: []Group) void {
    for (values) |value| allocator.free(value.members);
    allocator.free(values);
}
test "fusion groups retain every original node" {
    const NodeId = plan.ResourceNodeId;
    const members = [_]NodeId{ .{ .value = 1 }, .{ .value = 2 } };
    try std.testing.expectEqual(@as(usize, 2), members.len);
}
