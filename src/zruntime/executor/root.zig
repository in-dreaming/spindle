/// Cancellation tokens shared by executors and synchronization primitives.
pub const cancellation = @import("cancellation.zig");
pub const CancellationSource = cancellation.CancellationSource;
pub const CancellationToken = cancellation.CancellationToken;
