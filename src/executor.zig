//! Minimal public entry point for consumers that only need CPU execution.
//!
//! This surface intentionally excludes Runtime, parallel algorithms, Local
//! Task Graph, ECS, Resource Graph, Workflow, I/O, and observability. Consumers
//! own their domain scheduling, result ordering, and state publication.

pub const executor = @import("zruntime/executor/root.zig");
