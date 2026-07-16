# Spindle

Spindle is a general-purpose Zig runtime for concurrent execution and layered task orchestration. It provides shared low-level execution infrastructure while keeping four upper-level models semantically independent:

- Local Task Graph for low-overhead in-process DAG execution.
- Resource Graph for hazards, versions, incremental work, caching, and budgets.
- ECS for archetype/chunk storage, queries, and conflict-aware system scheduling.
- Durable Workflow for persistent event-driven state machines, Activities, timers, and recovery.

The project targets Zig `0.16.0` on Windows, Linux, and macOS. Tasks 00-22 are implemented and the repository is in its stabilization phase.

## Current Status

Implemented through task 22:

- Core IDs, clocks, schemas, errors, tracing, metrics, and stable codecs.
- Platform threads, synchronization primitives, concurrent queues, cancellation, and structured concurrency.
- Fixed, serial, blocking, pump, deterministic, and work-stealing executors.
- Parallel algorithms and the `std.Io` adapter boundary.
- Local Task Graph compilation, routing, execution, failure, and cancellation.
- Archetype/chunk ECS storage, queries, command buffers, scheduling, snapshots, rollback, and replay.
- Resource Graph hazards, budgets, commit/recovery, incremental cache, range tracking, and ArtifactStore integration.
- Database-independent Workflow protocol, deterministic replay, versioned definitions, retry policy, and snapshots.
- Optional embedded SQLite Workflow with crash recovery, Activities, timers, inbox/outbox, Child Workflows, compensation, operator controls, backup/restore, and verified archival.
- Aggregate Runtime ownership of lower-layer resources and optional SQLite Workflow infrastructure, with deadline-aware staged shutdown.
- Compile-time profiles for Task Graph, ECS, Resource Graph, Workflow, SQLite persistence, and archive adapters.

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
```

`test-all` runs compile checks, unit/integration tests, bounded stress, feature-boundary checks, and real temporary-file SQLite suites. No external database service is needed.

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

## Architecture

Dependencies point downward only:

```text
ECS -----------------> Local Task Graph / Executor
Resource Graph ------> Local Task Graph / Executor
Durable Workflow ----> Executor / Platform / Sync / I/O
```

Upper-level models share executors, clocks, codecs, cancellation, and observability, but do not share node types, schedulers, state machines, or persistence models. See [docs/arch.md](docs/arch.md) for the full design and [docs/tasks/setup.md](docs/tasks/setup.md) for implementation constraints.

## WIP

Only distributed Workflow concerns remain outside the implemented local runtime: partitioning, multi-process HA, remote coordination, and multi-region consistency. They require a future storage backend and evidence from a real deployment need.

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

## Development State

Changes require formatting, focused acceptance tests, `zig build test-all`, and diff review. Historical task specifications live in `docs/tasks/` as implementation contracts.
