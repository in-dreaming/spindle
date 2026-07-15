const std = @import("std");
const system = @import("system.zig");

/// Compiles explicit dependencies and declared access hazards into stable, conflict-free batches.
pub fn compile(allocator: std.mem.Allocator, registry: *const system.Registry) !system.CompiledSchedule {
    for (registry.systems.items) |entry| {
        for (entry.desc.before) |id| try validateDependency(registry, entry.desc, id);
        for (entry.desc.after) |id| try validateDependency(registry, entry.desc, id);
    }
    var phases: std.ArrayListUnmanaged(system.CompiledPhase) = .empty;
    errdefer {
        for (phases.items) |phase| {
            for (phase.batches) |batch| allocator.free(batch.systems);
            allocator.free(phase.batches);
        }
        phases.deinit(allocator);
    }
    for ([_]system.Phase{ .startup, .pre_update, .update, .post_update, .render }) |phase| {
        var ids: std.ArrayListUnmanaged(system.SystemId) = .empty;
        defer ids.deinit(allocator);
        for (registry.systems.items) |entry| if (entry.desc.phase == phase) try ids.append(allocator, entry.desc.id);
        if (ids.items.len == 0) continue;
        sortIds(registry, ids.items);
        var phase_batches = try compilePhase(allocator, registry, ids.items);
        try phases.append(allocator, .{ .phase = phase, .batches = try phase_batches.toOwnedSlice(allocator) });
    }
    return .{ .allocator = allocator, .phases = try phases.toOwnedSlice(allocator) };
}
fn validateDependency(registry: *const system.Registry, source: system.SystemDesc, target_id: system.SystemId) !void {
    const target = findConst(registry, target_id) orelse return error.UnknownSystem;
    if (target.desc.phase != source.phase) return error.CrossPhaseDependency;
}
fn compilePhase(allocator: std.mem.Allocator, registry: *const system.Registry, ids: []const system.SystemId) !std.ArrayListUnmanaged(system.Batch) {
    const n = ids.len;
    var edges = try allocator.alloc(bool, n * n);
    defer allocator.free(edges);
    @memset(edges, false);
    var indegree = try allocator.alloc(usize, n);
    defer allocator.free(indegree);
    @memset(indegree, 0);
    for (ids, 0..) |id, i| for (ids, 0..) |other, j| if (i != j) {
        const a = findConst(registry, id).?;
        const b = findConst(registry, other).?;
        if (explicitBefore(a.desc, b.desc) or (i < j and conflict(a.desc, b.desc))) edges[i * n + j] = true;
    };
    for (0..n) |i| {
        for (0..n) |j| {
            if (edges[i * n + j]) indegree[j] += 1;
        }
    }
    var result: std.ArrayListUnmanaged(system.Batch) = .empty;
    errdefer {
        for (result.items) |batch| allocator.free(batch.systems);
        result.deinit(allocator);
    }
    var emitted = try allocator.alloc(bool, n);
    defer allocator.free(emitted);
    @memset(emitted, false);
    var count: usize = 0;
    while (count < n) {
        var batch_ids: std.ArrayListUnmanaged(system.SystemId) = .empty;
        errdefer batch_ids.deinit(allocator);
        for (ids, 0..) |id, i| if (!emitted[i] and indegree[i] == 0) {
            var compatible = true;
            for (batch_ids.items) |existing| {
                if (conflict(findConst(registry, id).?.desc, findConst(registry, existing).?.desc)) compatible = false;
            }
            if (compatible) try batch_ids.append(allocator, id);
        };
        if (batch_ids.items.len == 0) return error.DependencyCycle;
        for (batch_ids.items) |id| {
            const i = indexOf(ids, id).?;
            emitted[i] = true;
            count += 1;
            for (0..n) |j| {
                if (edges[i * n + j]) indegree[j] -= 1;
            }
        }
        try result.append(allocator, .{ .systems = try batch_ids.toOwnedSlice(allocator) });
    }
    return result;
}
fn explicitBefore(a: system.SystemDesc, b: system.SystemDesc) bool {
    for (a.before) |id| if (id == b.id) return true;
    for (b.after) |id| if (id == a.id) return true;
    for (a.after) |id| if (id == b.id) return false;
    for (b.before) |id| if (id == a.id) return false;
    return false;
}
fn conflict(a: system.SystemDesc, b: system.SystemDesc) bool {
    return componentConflict(a.component_writes, a.component_reads, b.component_writes, b.component_reads) or
        componentConflict(a.query.write, a.query.read, b.query.write, b.query.read) or
        componentConflict(a.component_writes, a.component_reads, b.query.write, b.query.read) or
        componentConflict(a.query.write, a.query.read, b.component_writes, b.component_reads) or
        overlaps(a.resource_writes, b.resource_writes) or overlaps(a.resource_writes, b.resource_reads) or overlaps(b.resource_writes, a.resource_reads);
}
fn componentConflict(a_write: []const u64, a_read: []const u64, b_write: []const u64, b_read: []const u64) bool {
    return overlaps(a_write, b_write) or overlaps(a_write, b_read) or overlaps(b_write, a_read);
}
fn overlaps(a: []const u64, b: []const u64) bool {
    for (a) |x| for (b) |y| if (x == y) return true;
    return false;
}
fn indexOf(ids: []const system.SystemId, id: system.SystemId) ?usize {
    for (ids, 0..) |value, i| if (value == id) return i;
    return null;
}
fn findConst(registry: *const system.Registry, id: system.SystemId) ?*const system.Registered {
    for (registry.systems.items) |*item| if (item.desc.id == id) return item;
    return null;
}
fn sortIds(registry: *const system.Registry, ids: []system.SystemId) void {
    std.mem.sort(system.SystemId, ids, registry, struct {
        fn less(r: *const system.Registry, a: system.SystemId, b: system.SystemId) bool {
            _ = r;
            return a < b;
        }
    }.less);
}
