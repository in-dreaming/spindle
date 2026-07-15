/// Public package entry point. Importing this module performs no platform initialization.
/// Core primitives namespace. It has no initialization side effects.
pub const core = @import("zruntime/core/root.zig");
/// Platform abstraction namespace. It has no initialization side effects.
pub const platform = @import("zruntime/platform/root.zig");
/// Synchronization namespace. It has no initialization side effects.
pub const sync = @import("zruntime/sync/root.zig");
/// Concurrent-container namespace. It has no initialization side effects.
pub const concurrent = @import("zruntime/concurrent/root.zig");
/// Executor namespace. It has no initialization side effects.
pub const executor = @import("zruntime/executor/root.zig");
/// Parallel-algorithm namespace. It has no initialization side effects.
pub const parallel = @import("zruntime/parallel/root.zig");
/// Local task-graph namespace. It has no initialization side effects.
pub const task_graph = @import("zruntime/task_graph/root.zig");
/// ECS namespace. It has no initialization side effects.
pub const ecs = @import("zruntime/ecs/root.zig");
/// Resource-graph namespace. It has no initialization side effects.
pub const resource_graph = @import("zruntime/resource_graph/root.zig");
/// Durable-workflow namespace. It has no initialization side effects.
pub const workflow = @import("zruntime/workflow/root.zig");
/// std.Io adapter namespace. It has no initialization side effects.
pub const io_adapter = @import("zruntime/io_adapter/root.zig");
/// Observability namespace. It has no initialization side effects.
pub const observability = @import("zruntime/observability/root.zig");
/// Runtime-integration namespace. It has no initialization side effects.
pub const runtime = @import("zruntime/runtime/root.zig");
/// Testing-support namespace. It has no initialization side effects.
pub const testing = @import("zruntime/testing/root.zig");
