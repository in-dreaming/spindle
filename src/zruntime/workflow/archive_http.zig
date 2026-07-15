const resource_graph = @import("../resource_graph/root.zig");

/// Task-14 HTTP artifact adapter exposed only at the optional workflow archive edge.
pub const ArtifactStore = resource_graph.cache.ArtifactStore;
