# 17 - SQLite Persistence, Workflow Frontend, Scheduler and Worker

## Prerequisites

Complete 05, 15 and 16. Task 16's PostgreSQL implementation is historical input only: this task supersedes and removes it. Reuse the `game.login` v3 definition and golden data from `tests/fixtures/login_workflow.zig`.

## Goal

Deliver an optional, embedded SQLite persistence backend and a single-process Workflow client/scheduler/worker that can recover after a real process crash without Docker, DSN, libpq or an external service.

## Build and dependency boundary

- `-Dworkflow=true` enables the database-independent protocol, registry and replay implementation.
- `-Dworkflow-sqlite=true` implies workflow and is the only switch that compiles/links SQLite and persistence runtime code.
- Pin one maintained SQLite amalgamation package and content hash as a lazy `build.zig.zon` dependency; record version, source, compile options and public-domain status. Disabled builds must not fetch or resolve it. Enabled CI prepares the pinned dependency before offline compile/test execution.
- With SQLite disabled, no SQLite source/header/symbol may be compiled or linked and no persistence thread may be created. Add a link/import inspection test for this property.
- Remove the PostgreSQL option, libpq import/linkage, DSN handling, `test-postgres`, PostgreSQL CI service and obsolete public backend exports. Do not retain two production backends.
- Establish `zig build test-sqlite`; it must use real temporary database files. `test-all` invokes a separate SQLite-enabled test artifact without changing the default library feature set.

## SQLite storage contract

- Use WAL mode, foreign keys, exclusive locking and documented synchronous durability. Acceptance uses the durable setting, not an in-memory database.
- Versioned migrations create instance, history, workflow task, activity task, timer, snapshot, inbox, outbox, start-idempotency and metadata tables with constraints and indexes.
- Applied migrations are immutable and checksum-verified. Migration execution is transactional and serialized.
- A dedicated persistence dispatcher owns the only SQLite connection for a Workflow store and serializes reads/writes on a BlockingExecutor/dedicated thread. Workflow transitions never run while holding a database transaction.
- Statements/rows have explicit borrowing and finalize/reset rules. All SQL is parameterized and payload limits are enforced. Additional connection pooling is deferred until measurements justify it.
- Runtime startup increments a durable global `runtime_epoch`. Claimed work records that epoch; every completion transaction rejects a stale epoch. This is restart fencing, not multi-process HA.
- Only one active Workflow runtime per database is supported. It holds SQLite's exclusive store lock for its lifetime; a second opener returns stable `WorkflowStoreInUse` without changing the epoch or doing work.
- Durable UTC values come from injected `core.Clock`, sampled before a short write transaction. SQLite wall-clock functions must not control correctness.

## Public behavior

- `WorkflowClient.start`, `signal`, `requestCancel` and `getInstance` are the only public mutation/query entry points and enforce tenant/namespace authorization hooks.
- Start idempotency uses `(tenant, namespace, idempotency_key)` plus a canonical request hash. Same key/same request returns the original ID; conflicting content fails.
- Signal/cancel append an inbox-deduplicated event and ensure one ready task in the same transaction.
- Scheduler atomically claims ready tasks for the current runtime epoch without scanning all rows.
- Worker loads snapshot plus contiguous history, runs task 15 replay/transition outside the transaction, then calls the single atomic `commitWorkflowTaskTransition` entry point.
- The commit validates expected state version and runtime epoch, appends events, updates instance/snapshot, materializes commands and completes/requeues the task atomically.
- Unknown definition versions move a task to an explicit blocked state without changing history; registration can explicitly unblock the exact version.
- `WorkflowRuntime.start/shutdown(deadline)` owns and joins every loop/thread. No fire-and-forget thread is allowed.

## Crash semantics

- A real subprocess harness kills the worker after claim, before commit and after commit.
- On restart, the new runtime epoch safely reclaims incomplete tasks; committed transitions are not repeated and history remains contiguous.
- Corrupt schema, migration checksum mismatch, malformed payload and SQLite busy/full/I/O errors map to stable errors and never report success.

## Non-goals

- No PostgreSQL, Docker, remote database, partition, distributed lease, multi-process HA, Activity execution, timer scan, child workflow or archival.
- No in-memory repository or mocked SQL as persistence acceptance.

## Verification

- Feature matrix: workflow off; workflow core only; workflow plus SQLite.
- Empty/repeated/concurrent migration and modified migration rejection.
- Start/signal/cancel idempotency, authorization failure, concurrent decisions and stale runtime epoch.
- Snapshot plus tail and full-history replay produce identical state/commands.
- Real kill/restart matrix proves no missing/duplicate transition.
- Run `zig build test-all` and `zig build test-sqlite`.

## Acceptance checklist

- [ ] SQLite is fully absent when its feature is disabled.
- [ ] PostgreSQL/libpq/DSN/container requirements are removed.
- [ ] Each Workflow transition commits in one real SQLite transaction.
- [ ] Restart fencing and subprocess crash recovery pass.
- [ ] All validation passes on Windows, Linux and macOS.
