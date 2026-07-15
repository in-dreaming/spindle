const std = @import("std");
const StableId = @import("../core/stable_id.zig").StableId;

/// Correlation-only context propagated across runtime boundaries; it contains no business state.
pub const TraceContext = struct {
    trace_id: StableId,
    span_id: u64,
    parent_span_id: ?u64,

    /// Derives a child context while retaining the trace ID and recording the parent span.
    pub fn child(self: TraceContext, span_id: u64) TraceContext {
        return .{ .trace_id = self.trace_id, .span_id = span_id, .parent_span_id = self.span_id };
    }
};

/// Thread-safe monotonically incrementing span-ID source. Zero is never returned.
pub const SpanIdGenerator = struct {
    next_id: std.atomic.Value(u64) = .init(1),

    pub fn next(self: *SpanIdGenerator) u64 {
        const result = self.next_id.fetchAdd(1, .monotonic);
        return if (result == 0) self.next_id.fetchAdd(1, .monotonic) else result;
    }
};
