/// Resource identities, access declarations, and compiled hazard plans.
pub const resource_key = @import("resource_key.zig");
pub const resource_range = @import("resource_range.zig");
pub const access = @import("access.zig");
pub const version = @import("version.zig");
pub const manifest = @import("manifest.zig");
pub const dependency_builder = @import("dependency_builder.zig");
pub const plan = @import("plan.zig");
pub const budget = @import("budget.zig");
pub const scheduler = @import("scheduler.zig");
pub const commit = @import("commit.zig");
/// Incremental execution cache primitives.
pub const cache = @import("cache.zig");
/// Byte-range overlap index.
pub const interval_index = @import("interval_index.zig");
/// Conservative task-fusion metadata.
pub const fusion = @import("fusion.zig");
/// Dynamic execution cost estimates.
pub const cost = @import("cost.zig");

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
pub const ResourceCost = budget.ResourceCost;
pub const ExecutionBudget = budget.ExecutionBudget;
pub const ResourceExecutionHandle = scheduler.ExecutionHandle;
pub const ResourceSchedulerMetrics = scheduler.Metrics;
pub const CommitGroup = commit.CommitGroup;
pub const CommitPolicy = commit.CommitPolicy;
pub const CommitStore = commit.Store;
pub const Fingerprint = cache.Fingerprint;
pub const ArtifactCache = cache.DiskCas;
pub const IntervalIndex = interval_index.Index;
pub const FusionPolicy = fusion.Policy;
pub const CostEstimate = cost.Estimate;
