const spindle = @import("spindle");

pub fn main() void {
    _ = spindle.parallel;
    _ = spindle.executor.InlineExecutor{};
}
