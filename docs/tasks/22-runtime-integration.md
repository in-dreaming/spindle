# 22 - Runtime Integration, Feature Profiles and Release Gate

## Prerequisites

Complete all remaining tasks. Do not begin while any transitive dependency is incomplete.

## Goal

Assemble the public Runtime while preserving the independent semantics and compile-time removability of Executor, Local Graph, ECS, Resource Graph and Durable Workflow.

## Build-time feature contract

- Enforce the setup-defined `task-graph`, `ecs`, `resource-graph`, `workflow`, `workflow-sqlite`, `workflow-archive` and `workflow-archive-http` options; keep existing platform/I/O options where applicable.
- `resource-graph` implies task-graph; `workflow-sqlite` implies workflow; `workflow-archive` implies workflow-sqlite; `workflow-archive-http` implies workflow-archive and resource-graph. Invalid combinations fail during configuration with a specific diagnostic.
- Default library build includes core/executor/local graph, allows `-Dtask-graph=false`, and excludes third-party persistence dependencies. Profiles may enable larger combinations explicitly.
- Disabled modules are not parsed/compiled, linked, initialized or represented by background threads. They may expose a small compile-time unavailable marker only if required for a stable aggregate root.
- Generate a build-options module and use compile-time branches at module roots; do not scatter runtime booleans through hot paths.
- Add a feature-matrix build test and binary/import inspection proving SQLite and optional adapter symbols are absent when disabled.
- Publish `spindle_executor` from `src/executor.zig` as a build-options-free narrow
  entry point. It exports only the executor namespace and must not expose or
  require Runtime, parallel algorithms, Local Task Graph, ECS, Resource Graph,
  Workflow, I/O or observability.

## Runtime assembly

- Runtime owns compute, blocking, pumps, I/O adapter, clock and observability.
- Optional ECS, Resource Graph and Workflow subsystem constructors are available only for enabled features and retain their existing public APIs.
- SQLite Workflow owns its persistence dispatcher, scheduler, workers, timers and outbox publisher. Core-only Runtime has no database object or thread.
- Keep dependency direction: upper models point to executor/I/O/core; executor never imports ECS, Resource Graph or Workflow.
- Application Activity may compose Resource Graph, Local Graph and I/O, but workflow core never imports those upper semantics.
- Initialization failure unwinds acquired resources in reverse order. Partially initialized Runtime is never observable.

## Shutdown order

1. Reject new submissions to enabled upper modules.
2. Stop Workflow claims and converge Activity/timer/outbox loops when enabled.
3. Stop new Resource plans, then ECS frames.
4. Drain pumps and pending I/O according to policy.
5. Converge DetachedHandles, flush bounded observability, join threads and release optional stores.

Deadline expiry returns a report of outstanding work and never frees memory still reachable by a thread.

## Integration artifacts

- Compile/run examples for executor/parallel, local graph, ECS and Resource Graph only in profiles that enable them.
- SQLite durable workflow example uses a temporary/local database path and performs a real stop/reopen recovery; no DSN or external service.
- Runtime end-to-end test may route Workflow Activity through optional Resource Graph and Local Graph only when all relevant flags are enabled.
- Dependency-boundary checker, feature matrix, shutdown fault injection, inspector protocol and replay bundle are mandatory.
- The executor-only entry has its own import/run test and is part of `test-all`;
  upper module declarations on that root are a release failure.
- Inspector/replay formats describe only enabled modules and never query private SQLite tables directly.

## Release gate

- Windows, Linux and macOS run `test-all`; SQLite tests run locally on every platform with no service container.
- Verify release artifacts for each supported profile, public API docs, licenses, examples and benchmark schema.
- No required test skip, placeholder implementation, stale PostgreSQL command or undocumented feature implication.
- Run `zig build test-all`, `zig build test-sqlite`, profile matrix, examples and release checks.

## Acceptance checklist

- [ ] Every optional subsystem is absent from disabled builds, including dependencies and threads.
- [ ] `spindle_executor` remains a minimal standalone public module with no upper-model declarations.
- [ ] All feature combinations either build or fail with an intentional configuration error.
- [ ] Runtime initialization/shutdown is leak-free under injected failures.
- [ ] No PostgreSQL, libpq, DSN or Docker requirement remains.
- [ ] Cross-platform release gates pass.
