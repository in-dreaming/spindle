const std = @import("std");

/// Returns a deterministic FNV-1a content hash suitable for persistent checksums and golden data.
pub fn content(bytes: []const u8) u64 {
    var value: u64 = 0xcbf29ce484222325;
    for (bytes) |byte| {
        value ^= byte;
        value *%= 0x100000001b3;
    }
    return value;
}

/// A process-local keyed hash. Its seed must never be persisted or used in a wire format.
pub const ProcessHasher = struct {
    seed: u64,

    pub fn hash(self: ProcessHasher, bytes: []const u8) u64 {
        return std.hash.Wyhash.hash(self.seed, bytes);
    }
};
