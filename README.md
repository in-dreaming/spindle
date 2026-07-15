# Spindle

Spindle is a general-purpose Zig runtime for concurrent execution and layered task orchestration. It provides shared low-level execution infrastructure while keeping four upper-level models semantically independent:

- Local Task Graph for low-overhead in-process DAG execution.
- Resource Graph for hazards, versions, incremental work, caching, and budgets.
- ECS for archetype/chunk storage, queries, and conflict-aware system scheduling.
- Durable Workflow for persistent event-driven state machines, Activities, timers, and recovery.

The project targets Zig `0.16.0` on Windows, Linux, and macOS. It is under active development; implemented APIs are tested, but the aggregate Runtime and final feature/profile surface are still WIP.

## Current Status

Implemented through task 18:

- Core IDs, clocks, schemas, errors, tracing, metrics, and stable codecs.
- Platform threads, synchronization primitives, concurrent queues, cancellation, and structured concurrency.
- Fixed, serial, blocking, pump, deterministic, and work-stealing executors.
- Parallel algorithms and the `std.Io` adapter boundary.
- Local Task Graph compilation, routing, execution, failure, and cancellation.
- Archetype/chunk ECS storage, queries, command buffers, scheduling, snapshots, rollback, and replay.
- Resource Graph hazards, budgets, commit/recovery, incremental cache, range tracking, and ArtifactStore integration.
- Database-independent Workflow protocol, deterministic replay, versioned definitions, retry policy, and snapshots.
- Optional embedded SQLite Workflow backend with WAL/FULL durability, migrations, runtime-epoch fencing, client/scheduler/worker, crash recovery, Activities, durable timers, inbox, and outbox.

PostgreSQL, libpq, DSNs, and service containers are not required. SQLite is an optional, pinned lazy dependency and is excluded from the default build unless its backend is enabled or SQLite tests are requested.

## Build

```powershell
zig build check
zig build test
zig build test-stress
zig build test-sqlite
zig build bench -Doptimize=ReleaseFast
zig build test-all
```

`test-all` runs check, unit/integration, bounded stress, feature-boundary, and real temporary-file SQLite suites. No external database service is needed.

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

`-Dworkflow-sqlite=true` requires Workflow to remain enabled. When SQLite is disabled, its amalgamation is not resolved, compiled, or linked.

The final build-profile task will add independent compile-time gates for Local Task Graph, ECS, Resource Graph, Workflow persistence, and archival adapters. Disabled subsystems must contribute no third-party linkage, background threads, or runtime initialization cost.

## Architecture

Dependencies point downward only:

```text
ECS ────────────────┐
Resource Graph ─────┼──> Local Task Graph / Executor
Durable Workflow ───┘             │
                                  v
                         Platform / Sync / I/O
```

Upper-level models share executors, clocks, codecs, cancellation, and observability, but do not share node types, schedulers, state machines, or persistence models. See [docs/arch.md](docs/arch.md) for the full design and [docs/tasks/setup.md](docs/tasks/setup.md) for implementation constraints.

## WIP

The remaining roadmap is explicit and sequential:

- Task 19: local Workflow recovery, integrity checks, bounded repair, backup/restore, WAL checkpointing, and maintenance diagnostics.
- Task 20: Child Workflow lifecycle and recoverable compensation.
- Task 21: definition migration, optional archival, security boundaries, audit, and operator APIs.
- Task 22: aggregate Runtime assembly, complete compile-time feature matrix, shutdown integration, inspector/replay bundle, examples, and release gates.

Distributed Workflow partitioning, multi-process HA, remote database coordination, and multi-region consistency are not part of the current roadmap. They require a future storage backend and evidence from a real deployment need.

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

Task completion requires formatting, focused acceptance tests, `zig build test-all`, diff review, and an exact task commit. WIP task specifications live in `docs/tasks/`; they are implementation contracts rather than claims that unfinished APIs already exist.
