const key = @import("resource_key.zig");
const range = @import("resource_range.zig");

pub const AccessMode = enum(u8) { read, write, create, delete };
pub const VersionConstraint = union(enum) { any, must_not_exist, exact: u64, generation: u64 };
/// A node's declaration for one resource. It borrows the key and any custom range bytes.
pub const ResourceAccess = struct {
    key: key.ResourceKey,
    range: range.ResourceRange = .whole,
    mode: AccessMode,
    version: VersionConstraint = .any,
    pub fn validate(self: ResourceAccess) !void {
        try self.range.validate(self.key);
        if (self.mode == .create and self.version != .must_not_exist) return error.InvalidVersionConstraint;
        if (self.mode != .create and self.version == .must_not_exist) return error.InvalidVersionConstraint;
    }
    pub fn isWriter(self: ResourceAccess) bool {
        return self.mode != .read;
    }
};
