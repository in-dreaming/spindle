const std = @import("std");
const executor = @import("../executor/root.zig");
const parallel_for = @import("parallel_for.zig");

pub const Options = struct { grain: ?usize = null };
/// Writes an exclusive scan using parallel chunk totals followed by parallel chunk fills.
pub fn exclusive(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, input: []const T, output: []T, initial: T, combine: *const fn (T, T) T) !void {
    return exclusiveWithOptions(allocator, target, T, input, output, initial, .{}, combine);
}
pub fn exclusiveWithOptions(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, input: []const T, output: []T, initial: T, options: Options, combine: *const fn (T, T) T) !void {
    if (input.len != output.len) return error.LengthMismatch;
    if (input.len == 0) return;
    const geometry = parallel_for.chunkGeometry(target, input.len, options.grain);
    const offsets = try allocator.alloc(T, geometry.chunks);
    defer allocator.free(offsets);
    const State = struct { input: []const T, output: []T, offsets: []T, grain: usize, initial: T, combine_fn: *const fn (T, T) T };
    var state = State{ .input = input, .output = output, .offsets = offsets, .grain = geometry.grain, .initial = initial, .combine_fn = combine };
    try parallel_for.forRange(allocator, target, .{ .end = input.len }, .{ .grain = geometry.grain }, &state, struct {
        fn totals(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            var total = s.initial;
            for (s.input[begin..end]) |item| total = s.combine_fn(total, item);
            s.offsets[begin / s.grain] = total;
        }
    }.totals);
    var prefix = initial;
    for (offsets) |*offset| {
        const total = offset.*;
        offset.* = prefix;
        prefix = combine(prefix, total);
    }
    try parallel_for.forRange(allocator, target, .{ .end = input.len }, .{ .grain = geometry.grain }, &state, struct {
        fn fill(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            var value = s.offsets[begin / s.grain];
            for (begin..end) |index| {
                s.output[index] = value;
                value = s.combine_fn(value, s.input[index]);
            }
        }
    }.fill);
}
/// Writes an inclusive prefix scan. `combine` must be associative.
pub fn inclusive(allocator: std.mem.Allocator, target: executor.Executor, comptime T: type, input: []const T, output: []T, combine: *const fn (T, T) T) !void {
    if (input.len != output.len) return error.LengthMismatch;
    if (input.len == 0) return;
    const geometry = parallel_for.chunkGeometry(target, input.len, null);
    const offsets = try allocator.alloc(T, geometry.chunks);
    defer allocator.free(offsets);
    const State = struct { input: []const T, output: []T, offsets: []T, grain: usize, combine_fn: *const fn (T, T) T };
    var state = State{ .input = input, .output = output, .offsets = offsets, .grain = geometry.grain, .combine_fn = combine };
    try parallel_for.forRange(allocator, target, .{ .end = input.len }, .{ .grain = geometry.grain }, &state, struct {
        fn totals(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            var total = s.input[begin];
            for (s.input[begin + 1 .. end]) |item| total = s.combine_fn(total, item);
            s.offsets[begin / s.grain] = total;
        }
    }.totals);
    var prefix = offsets[0];
    for (offsets, 0..) |*offset, index| {
        const total = offset.*;
        offset.* = prefix;
        if (index != 0) prefix = combine(prefix, total);
    }
    try parallel_for.forRange(allocator, target, .{ .end = input.len }, .{ .grain = geometry.grain }, &state, struct {
        fn fill(s: *State, begin: usize, end: usize, _: executor.CancellationToken) !void {
            var value = if (begin == 0) s.input[0] else s.combine_fn(s.offsets[begin / s.grain], s.input[begin]);
            s.output[begin] = value;
            for (begin + 1..end) |index| {
                value = s.combine_fn(value, s.input[index]);
                s.output[index] = value;
            }
        }
    }.fill);
}
