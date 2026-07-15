/// Native thread lifecycle helpers.
pub const thread = @import("thread.zig");
/// CPU topology and affinity capability helpers.
pub const topology = @import("topology.zig");
pub const affinity = @import("affinity.zig");
/// Thread priority capability helpers.
pub const priority = @import("priority.zig");
/// Uniform parking API used by synchronization primitives.
pub const park = @import("park.zig");
/// Target-selected platform parking facade. Only the active target file is imported.
pub const native = switch (@import("builtin").os.tag) {
    .windows => @import("windows.zig"),
    .linux => @import("linux.zig"),
    .macos => @import("macos.zig"),
    else => @import("park.zig"),
};
