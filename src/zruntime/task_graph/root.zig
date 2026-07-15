/// One-shot in-process directed acyclic task graphs.
pub const unavailable = false;
pub const node = @import("node.zig");
pub const LocalTaskGraph = @import("builder.zig").LocalTaskGraph;
pub const CompiledLocalTaskGraph = @import("compiled_graph.zig").CompiledLocalTaskGraph;
pub const GraphExecutionHandle = @import("execution.zig").GraphExecutionHandle;
pub const start = @import("execution.zig").start;
pub const NodeId = node.NodeId;
pub const LocalTaskState = node.LocalTaskState;
pub const TaskContext = node.TaskContext;
pub const TaskFn = node.TaskFn;
