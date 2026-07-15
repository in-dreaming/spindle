/// Windows parking is supplied through std.Io's WaitOnAddress-backed futex implementation.
pub const park = @import("park.zig");
