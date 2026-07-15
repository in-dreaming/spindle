const core = @import("../core/root.zig");
const event = @import("event.zig");

/// Durable compensation item state. Completed items are executed in descending index order.
pub const Status = enum { pending, running, completed, failed };
pub const schema = core.schema.SchemaKey{ .id = 0x636f_6d70_5f7631, .version = 1 };
pub const PlanItem = struct { activity_type: u64, input_schema: core.schema.SchemaKey, input_hash: u64, index: u32, status: Status, input: event.Payload };
