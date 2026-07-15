# 18 - Activity, Retry, Durable Timer and Local Messaging

## Prerequisites

Complete 17 and reuse its SQLite transaction API, runtime epoch and process harness. Reuse the canonical login workflow fixture rather than creating a second transition implementation.

## Goal

Complete side-effect execution, retry/timeout, durable timers and inbox/outbox for the single-process SQLite Workflow runtime.

## Implementation scope

- Add an Activity registry with stable type/schema IDs, handler ownership, idempotency requirement and allowed executor.
- Activity worker atomically claims SQLite rows for the current runtime epoch, runs blocking handlers on BlockingExecutor and CPU handlers on ComputeExecutor, then commits result/failure as a Workflow event.
- `ActivityContext` exposes ActivityKey, attempt, deadline, cancellation, trace and heartbeat. It never exposes mutable Workflow state.
- Activity delivery is at-least-once. Production registration requires an idempotency contract; tests use a separate real SQLite business database keyed by ActivityKey to prove duplicate delivery returns the original result without bypassing the Workflow store dispatcher.
- Implement schedule-to-start, start-to-close and heartbeat timeouts plus deterministic retry/backoff decisions recorded in history.
- Durable timers use indexed `fire_at_utc_ms`, injected UTC clock and short SQLite claim/fire transactions. An in-memory heap may accelerate wake-up but is never authoritative.
- Inbox deduplicates by message ID. Outbox persists intent with the state transition, publishes through an injected transport, then marks completion; send-before-mark may duplicate and receivers must be idempotent.
- Outbox transport is a facade. The default test transport is loopback; HTTP or other transports are separate optional adapters and are not linked by workflow-sqlite alone.
- `WorkflowSubsystem.init/start/shutdown(deadline)` composes worker, Activity worker, timer scanner and outbox publisher with explicit startup rollback and joined shutdown.

## SQLite transaction rules

- Activity completion/failure, timer fire and inbox acceptance each append their event, wake the Workflow and finish their queue item atomically.
- External side effects are never held inside a SQLite transaction.
- Runtime epoch is validated on completion. Restart reclaims unfinished queue items; stale completions fail.
- Busy/full/I/O failures roll back fully and are classified retryable/non-retryable without sleeping in tests.

## Feature boundary

- Requires `-Dworkflow-sqlite=true`; workflow core-only builds contain event/command protocol but no workers, SQLite or transport loops.
- Optional HTTP/Resource Graph integrations are enabled by their own flags and cannot become reverse dependencies of workflow core.

## Non-goals

- No PostgreSQL, distributed scheduler, partition, multi-process HA, child workflow, compensation or remote broker.
- No exactly-once claim for arbitrary external side effects.

## Verification

- Real subprocess kills after Activity side effect, before/after result commit, after timer claim and after outbox send.
- Duplicate delivery, retryable/non-retryable exhaustion, all timeout classes, cancellation and heartbeat races.
- Timer restart, clock jump policy, ordering and no busy polling.
- Outbox duplicate send and inbox deduplication with a real SQLite receiver table.
- Shutdown with short/long Activity and pending timer/outbox work.
- Run `zig build test-all` and `zig build test-sqlite`.

## Acceptance checklist

- [ ] Every side effect is an idempotent Activity.
- [ ] Timer/inbox/outbox facts survive a real restart.
- [ ] Stale runtime work cannot commit.
- [ ] Optional transports add no cost when disabled.
- [ ] Full validation passes without an external service.
