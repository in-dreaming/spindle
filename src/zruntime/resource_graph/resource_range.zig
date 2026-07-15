const key = @import("resource_key.zig");

/// Range declarations. MVP accepts only whole resources and pages.
pub const ResourceRange = union(enum) {
    whole,
    page: u64,
    byte: struct { start: u64, end: u64 },
    texture: struct { mip: u32, layer: u32 },
    custom: []const u8,
    pub fn validate(self: ResourceRange, resource: key.ResourceKey) !void {
        return switch (self) {
            .whole => {},
            .page => if (resource.kind != .file and resource.kind != .page) error.InvalidPageRange else {},
            .byte, .texture, .custom => error.UnsupportedRange,
        };
    }
    pub fn overlaps(a: ResourceRange, b: ResourceRange) bool {
        return switch (a) {
            .whole => true,
            .page => |p| switch (b) {
                .whole => true,
                .page => |q| p == q,
                else => false,
            },
            else => false,
        };
    }
};
