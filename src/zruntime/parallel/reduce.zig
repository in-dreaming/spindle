const std = @import("std");
const executor = @import("../executor/root.zig");
const parallel_for = @import("parallel_for.zig");

pub const Options = struct { deterministic: bool = false, grain: ?usize = null };
/// Reduces bounded chunks in parallel. `combine` must be associative; callers
/// requesting deterministic order receive the chunk results in input order.
pub fn reduce(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, items: []const T, initial: T, options: Options, combine: *const fn (T, T) T) !T {
    if (items.len == 0) return initial;
    const geometry = parallel_for.chunkGeometry(target, items.len, options.grain);
    const partials = try allocator.alloc(T, geometry.chunks);
    defer allocator.free(partials);
    const State = struct { input: []const T, partials: []T, grain: usize, initial: T, combine_fn: *const fn (T, T) T };
    var state = State{ .input = items, .partials = partials, .grain = geometry.grain, .initial = initial, .combine_fn = combine };
    try parallel_for.forRange(allocator, target, .{ .end = items.len }, .{ .grain = geometry.grain }, &state, struct {
        fn run(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            var value = s.input[begin];
            for (s.input[begin + 1 .. end]) |item| value = s.combine_fn(value, item);
            s.partials[begin / s.grain] = value;
        }
    }.run);
    var result = initial;
    // A deterministic final fold is intentional: it avoids changing floating-point results.
    for (partials) |partial| result = combine(result, partial);
    return result;
}
