/// Isolated wrapper for Zig's std.Io futures and groups.
pub const IoRuntime = @import("io_runtime.zig").IoRuntime;
/// Completion delivery onto an executor.
pub const completion = @import("completion.zig");
pub const Completion = completion.Completion;
/// Explicit bridge for unavoidable blocking work.
pub const blocking_bridge = @import("blocking_bridge.zig");
pub const BlockingBridge = blocking_bridge.BlockingBridge;
