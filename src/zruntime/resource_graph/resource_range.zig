const key = @import("resource_key.zig");

/// Range declarations. Byte ranges are half-open and participate in hazard checks.
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
            .byte => |range| if (range.start >= range.end) error.InvalidByteRange else {},
            .texture, .custom => error.UnsupportedRange,
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
            .byte => |left| switch (b) {
                .whole => true,
                .byte => |right| left.start < right.end and right.start < left.end,
                else => false,
            },
            else => false,
        };
    }
};
