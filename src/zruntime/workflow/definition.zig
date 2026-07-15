const std = @import("std");
const core = @import("../core/root.zig");
const event = @import("event.zig");
const command = @import("command.zig");
const instance = @import("instance.zig");

pub const WorkflowDefinitionId = u64;
pub const SchemaSet = struct { state: core.schema.SchemaKey, event: core.schema.SchemaKey, command: core.schema.SchemaKey };
/// Atomic transition result. The caller publishes state, commands, and status together or not at all.
pub const Outcome = struct { new_state: []const u8, status: instance.Status = .running };

/// The only transition capability surface: logical time, recorded random values, trace, and commands.
pub const WorkflowContext = struct {
    logical_utc_ms: i64,
    random_values: []const u64,
    trace: ?@import("../observability/trace.zig").TraceContext = null,
    commands: *command.Buffer,
    random_index: usize = 0,
    pub fn nextRandom(self: *WorkflowContext) error{MissingRecordedRandom}!u64 {
        if (self.random_index == self.random_values.len) return error.MissingRecordedRandom;
        defer self.random_index += 1;
        return self.random_values[self.random_index];
    }
};

/// Pure workflow transition. State and payload aliases only immutable history/snapshot bytes.
pub const TransitionFn = *const fn (context: *WorkflowContext, state: []const u8, input: event.Event) anyerror!Outcome;
pub const Definition = struct { id: WorkflowDefinitionId, stable_name: []const u8, version: u32, schemas: SchemaSet, transition: TransitionFn };
pub const Error = error{ Frozen, DuplicateId, DuplicateName, DuplicateVersion, UnknownDefinition, UnknownVersion };

/// Setup-time registry. After freeze, immutable concurrent lookup is safe while its owner lives.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Definition) = .empty,
    frozen: bool = false,
    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .allocator = allocator };
    }
    pub fn deinit(self: *Registry) void {
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    pub fn register(self: *Registry, value: Definition) (Error || std.mem.Allocator.Error)!void {
        if (self.frozen) return error.Frozen;
        for (self.entries.items) |entry| {
            if (entry.id == value.id and entry.version == value.version) return error.DuplicateVersion;
            if (entry.id != value.id and std.mem.eql(u8, entry.stable_name, value.stable_name)) return error.DuplicateName;
            if (entry.id == value.id and !std.mem.eql(u8, entry.stable_name, value.stable_name)) return error.DuplicateId;
        }
        try self.entries.append(self.allocator, value);
    }
    pub fn freeze(self: *Registry) void {
        self.frozen = true;
    }
    pub fn find(self: *const Registry, id: WorkflowDefinitionId, version: u32) Error!Definition {
        var known = false;
        for (self.entries.items) |entry| {
            if (entry.id == id) {
                known = true;
                if (entry.version == version) return entry;
            }
        }
        return if (known) error.UnknownVersion else error.UnknownDefinition;
    }
};
