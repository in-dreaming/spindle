/// Stable error values allowed to cross persistence and network boundaries.
pub const ErrorCode = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    not_found = 2,
    conflict = 3,
    cancelled = 4,
    deadline_exceeded = 5,
    unavailable = 6,
    resource_exhausted = 7,
    corrupt_data = 8,
    internal = 9,
    unknown = 0xffff_ffff,
};

/// Broad failure classification that remains stable when internal Zig errors evolve.
pub const FailureClass = enum(u8) { none, caller, transient, permanent, corruption, cancelled };

/// A wire-safe error representation. `raw_code` preserves unknown future numeric values.
pub const ErrorEnvelope = struct {
    raw_code: u32,
    class: FailureClass,

    pub fn code(self: ErrorEnvelope) ?ErrorCode {
        return std.meta.intToEnum(ErrorCode, self.raw_code) catch null;
    }
};

const std = @import("std");

/// Maps internal errors to stable boundary values without exposing Zig error names.
pub fn fromInternal(err: anyerror) ErrorEnvelope {
    const code: ErrorCode = switch (err) {
        error.OutOfMemory => .resource_exhausted,
        error.InvalidArgument => .invalid_argument,
        error.NotFound => .not_found,
        error.Cancelled => .cancelled,
        error.Timeout => .deadline_exceeded,
        error.EndOfStream, error.InvalidCharacter, error.BadChecksum => .corrupt_data,
        else => .internal,
    };
    return .{ .raw_code = @intFromEnum(code), .class = classify(code) };
}

/// Classifies a stable code, preserving unknown values as permanent unknown failures.
pub fn classify(code: ErrorCode) FailureClass {
    return switch (code) {
        .ok => .none,
        .invalid_argument, .not_found, .conflict => .caller,
        .cancelled => .cancelled,
        .deadline_exceeded, .unavailable, .resource_exhausted => .transient,
        .corrupt_data => .corruption,
        .internal, .unknown => .permanent,
    };
}
