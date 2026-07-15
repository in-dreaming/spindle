/// Resource identities, access declarations, and compiled hazard plans.
pub const resource_key = @import("resource_key.zig");
pub const resource_range = @import("resource_range.zig");
pub const access = @import("access.zig");
pub const version = @import("version.zig");
pub const manifest = @import("manifest.zig");
pub const dependency_builder = @import("dependency_builder.zig");
pub const plan = @import("plan.zig");

pub const ResourceKey = resource_key.ResourceKey;
pub const FileIdentity = resource_key.FileIdentity;
pub const ResourceRange = resource_range.ResourceRange;
pub const AccessMode = access.AccessMode;
pub const ResourceAccess = access.ResourceAccess;
pub const VersionConstraint = access.VersionConstraint;
pub const ResourceVersion = version.ResourceVersion;
pub const ResourceManifest = manifest.ResourceManifest;
pub const ResourceTaskGraph = dependency_builder.ResourceTaskGraph;
pub const CompiledResourcePlan = plan.CompiledResourcePlan;
