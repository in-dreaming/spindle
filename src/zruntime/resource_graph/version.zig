const core = @import("../core/root.zig");
pub const State = enum(u8) { present, tombstone };
/// Immutable version produced by every exclusive access.
pub const ResourceVersion = struct {
    generation: u64,
    content_hash: ?u64 = null,
    state: State = .present,
    producer_fingerprint: core.StableId = core.StableId.zero,
    pub fn next(self: ResourceVersion, mode: @import("access.zig").AccessMode, content_hash: ?u64) !ResourceVersion {
        if (mode == .read or mode == .create and self.state == .present) return error.InvalidLifecycle;
        return .{ .generation = self.generation + 1, .content_hash = content_hash, .state = if (mode == .delete) .tombstone else .present, .producer_fingerprint = self.producer_fingerprint };
    }
};
