const std = @import("std");
const spindle = @import("spindle");

test "HTTP archive edge exposes task-14 adapter only when enabled" {
    try std.testing.expect(@hasDecl(spindle.workflow.archive, "LocalArtifactStore"));
    try std.testing.expect(@hasDecl(spindle.workflow.archive_http, "ArtifactStore"));
}
