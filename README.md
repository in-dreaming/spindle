# Spindle

Spindle is a general-purpose Zig runtime for concurrent execution and layered task orchestration. It provides shared low-level execution infrastructure while keeping four upper-level models semantically independent:

- Local Task Graph for low-overhead in-process DAG execution.
- Resource Graph for hazards, versions, incremental work, caching, and budgets.
- ECS for archetype/chunk storage, queries, and conflict-aware system scheduling.
- Durable Workflow for persistent event-driven state machines, Activities, timers, and recovery.

The project targets Zig `0.16.0` on Windows, Linux, and macOS. Its default profile provides the core runtime, Local Task Graph, and database-independent Workflow APIs; heavier models and persistence adapters are selected at compile time.

## Capabilities

- Core IDs, clocks, schemas, errors, tracing, metrics, and stable codecs.
- Platform threads, synchronization primitives, concurrent queues, cancellation, and structured concurrency.
- Fixed, serial, blocking, pump, deterministic, and work-stealing executors.
- Parallel algorithms and the `std.Io` adapter boundary.
- Local Task Graph compilation, routing, execution, failure, and cancellation.
- Archetype/chunk ECS storage, queries, command buffers, scheduling, snapshots, rollback, and replay.
- Resource Graph hazards, budgets, commit/recovery, incremental cache, range tracking, and artifact storage integration.
- Database-independent Workflow protocol, deterministic replay, versioned definitions, retry policy, and snapshots.
- Optional embedded SQLite Workflow with crash recovery, Activities, timers, inbox/outbox, Child Workflows, compensation, operator controls, backup/restore, and verified archival.
- Aggregate Runtime ownership of lower-layer resources and optional SQLite Workflow infrastructure, with deadline-aware staged shutdown.
- Compile-time isolation for Task Graph, ECS, Resource Graph, Workflow, SQLite persistence, and archive adapters.

PostgreSQL, libpq, DSNs, and service containers are not required. SQLite is an optional, pinned lazy dependency and is excluded from the default build unless its backend is enabled or SQLite tests are requested.

## Build

```powershell
zig build check
zig build test
zig build test-stress
zig build test-sqlite
zig build test-feature-matrix
zig build bench -Doptimize=ReleaseFast
zig build test-all
zig build release-check -Doptimize=ReleaseSafe
```

`check` runs the examples available in the selected feature profile. `test-all`
runs unit/integration tests, bounded stress, feature-boundary checks, every
supported-profile example, and real temporary-file SQLite suites. The SQLite
suite also runs `examples/workflow_sqlite_recovery.zig`, which stops and reopens
a local database before verifying its workflow record. `release-check` adds API
documentation, license installation, ReleaseSafe profile artifacts, and the
versioned benchmark schema. No external database service is needed.

Increase bounded stress coverage with:

```powershell
zig build test-stress -Dstress-iterations=1024
```

## Workflow Features

The database-independent Workflow protocol is enabled by default. The SQLite implementation is disabled by default:

```powershell
# Core runtime without any Workflow API.
zig build check -Dworkflow=false

# Workflow protocol and replay, without SQLite linkage or persistence threads.
zig build check -Dworkflow=true

# Workflow protocol plus embedded SQLite persistence.
zig build check -Dworkflow-sqlite=true
```

`-Dworkflow-sqlite=true` requires Workflow to remain enabled. When SQLite is disabled, its amalgamation is not resolved, compiled, or linked. Disabled subsystems contribute no background threads or runtime initialization cost.

Feature dependencies are explicit: Resource Graph requires Task Graph; SQLite requires Workflow; local archive requires SQLite; HTTP archive requires local archive and Resource Graph. Invalid combinations fail during build configuration instead of silently enabling a partial subsystem.

Consumers that only require CPU execution should import the public
`spindle_executor` module. Its root is `src/executor.zig` and intentionally has
no Runtime, parallel algorithm, Local Task Graph, ECS, Resource Graph, Workflow,
I/O, or observability declarations. Domain libraries remain responsible for
their own work partitioning, result ordering, and state publication.

## Runtime Ownership and Shutdown

The aggregate Runtime owns compute and blocking pools, the caller-thread Pump executor, I/O and observability adapters, detached-task tracking, and, when enabled, SQLite Workflow polling infrastructure. SQLite-disabled builds omit the Workflow configuration field entirely.

SQLite-enabled callers can independently size each polling class and the deterministic command buffer:

```zig
var runtime = try spindle.runtime.Runtime.init(allocator, .{
    .io = io,
    .compute_workers = 4,
    .blocking_workers = 2,
    .workflow = .{
        .database_path = "spindle.db",
        .tenant = "example",
        .namespace = "default",
        .definitions = definitions,
        .activities = activities,
        .transport = transport,
        .workflow_workers = 2,
        .activity_workers = 4,
        .timer_workers = 1,
        .publisher_workers = 1,
        .command_capacity = 128,
    },
});
defer runtime.deinit();
```

Shutdown first requests every component to stop, then waits in stages against one monotonic deadline. A finite deadline cancels pending Pump work so caller-thread tasks cannot overrun it; `shutdown(null)` drains Pump work and waits without a deadline. `ShutdownReport` distinguishes a timed-out stage from a worker failure and reports outstanding Workflow workers, executor workers, Pump work, and detached tasks. `deinit` always performs the final unbounded join and release, including after an earlier timeout or worker failure.

## Workflow Archive Storage

The optional archive module exposes one type-erased `archive.Storage` contract with `put` and `get`. `LocalArtifactStore.storage()` and `archive_http.ArtifactStore.storage()` provide the same interface, so archival and verified history reads do not depend on a concrete transport.

Archive locations are lowercase SHA-256 content keys. Before hot history is removed, Spindle writes and reads back the artifact, verifies the envelope checksum, manifest checksum, range, count, location, and continuous event sequence, then commits the archive manifest atomically. History reads repeat these checks while composing archived records with the hot tail.

## Architecture

Dependencies point downward only:

```text
ECS -----------------> Local Task Graph / Executor
Resource Graph ------> Local Task Graph / Executor
Durable Workflow ----> Executor / Platform / Sync / I/O
```

Upper-level models share executors, clocks, codecs, cancellation, and observability, but do not share node types, schedulers, state machines, or persistence models. See [docs/arch.md](docs/arch.md) for the full design and [docs/contributing.md](docs/contributing.md) for development requirements.

## Scope and Boundaries

Spindle is an in-process and single-host runtime. Its SQLite Workflow backend provides durable local execution, restart fencing, recovery, backup/restore, and archival, but it is not a distributed workflow service. Partitioning, multi-process high availability, remote coordination, and multi-region consistency are intentionally outside the current scope.

The upper-level models are complementary rather than interchangeable. Local Task Graph handles ephemeral DAG execution; Resource Graph adds resource hazards and incremental state; ECS manages simulation-oriented entity data; Durable Workflow persists event-driven business processes. Applications can enable only the models they need.

## Repository Layout

```text
src/zruntime/
  core/ platform/ sync/ concurrent/
  executor/ parallel/ io_adapter/
  task_graph/ ecs/ resource_graph/ workflow/
  observability/ runtime/ testing/
db/migrations/
tests/unit.zig
tests/{integration,stress,fixtures}/
bench/
examples/
```

The public package entry point is `src/root.zig`. Cross-module code should import public module roots rather than private implementation files.

## Development

Changes require formatting, focused acceptance tests, `zig build test-all`, minimum/maximum feature-profile compilation, and diff review. Public APIs should remain feature-isolated, and SQLite migration contents must remain immutable after release.
