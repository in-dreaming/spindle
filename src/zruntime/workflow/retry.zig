const std = @import("std");
const activity = @import("activity.zig");

/// Pure retry policy. Jitter is deterministic and its selected delay belongs in command metadata.
pub const Policy = activity.RetryPolicy;

pub fn shouldRetry(policy: Policy, attempt: u32, failure: activity.Failure) bool {
    if (attempt >= policy.max_attempts or failure.kind == .non_retryable) return false;
    for (policy.non_retryable) |code| if (code == failure.code) return false;
    return true;
}

/// Computes a reproducible bounded exponential delay. `seed` is persisted with the decision.
pub fn delayMs(policy: Policy, attempt: u32, seed: u64) u64 {
    if (attempt == 0 or policy.initial_backoff_ms == 0) return 0;
    var delay = policy.initial_backoff_ms;
    var exponent: u32 = 1;
    while (exponent < attempt and delay < policy.max_backoff_ms) : (exponent += 1) delay = std.math.mul(u64, delay, 2) catch policy.max_backoff_ms;
    delay = @min(delay, policy.max_backoff_ms);
    if (policy.jitter_percent == 0) return delay;
    const span = (delay / 100) * @as(u64, policy.jitter_percent);
    if (span == 0) return delay;
    const offset = seed % (span * 2 + 1);
    return delay - span + offset;
}
