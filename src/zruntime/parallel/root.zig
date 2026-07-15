/// Bounded-granularity parallel iteration algorithms.
pub const parallel_for = @import("parallel_for.zig");
pub const Range = parallel_for.Range;
pub const Options = parallel_for.Options;
pub const forRange = parallel_for.forRange;
pub const forEach = parallel_for.forEach;
pub const invoke = parallel_for.invoke;
/// Parallel reduction algorithms.
pub const reduce = @import("reduce.zig");
/// Inclusive and exclusive prefix scans.
pub const scan = @import("scan.zig");
/// Stable and unstable sorting entry points.
pub const sort = @import("sort.zig");
/// Bounded synchronous pipeline utilities.
pub const pipeline = @import("pipeline.zig");
