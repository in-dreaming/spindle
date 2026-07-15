# 20 - Child Workflow and Recoverable Compensation

## Prerequisites

Complete 19. Reuse the local SQLite persistence, runtime epoch, Activity semantics and recovery harness.

## Goal

Add optional Child Workflow composition and durable compensation without introducing distributed ownership assumptions.

## Protocol and implementation

- Add stable events for child started/completed/failed/cancelled, workflow terminated and compensation plan/step transitions. Update schema golden and replay verification.
- Enable existing `start_child`/`cancel_child` commands. Parent-child creation, relation row and parent history event commit in one SQLite transaction.
- Child has an independent WorkflowId, history and snapshot. The parent learns completion only through a persisted event.
- Implement `ParentClosePolicy`: abandon, request_cancel and terminate, with stable encoding and idempotent application.
- Persist a CompensationPlan containing ordered Activity type/schema/input hash/index/status. Execute completed business steps in reverse order using task 18 ActivityKey/idempotency semantics.
- A failed compensation step follows its retry policy; exhaustion leaves an explicit diagnosable failed plan and never reports completion.
- Parent/child/compensation commits validate the current runtime epoch and expected state version.
- Child and compensation support are part of `-Dworkflow=true` protocol but execution/storage is present only with `-Dworkflow-sqlite=true`.

## Non-goals

- No partition, distributed parent/child placement, cross-database transaction, remote scheduler or multi-process HA.
- No rollback fiction for already committed external side effects.

## Verification

- Complete/fail/cancel and all parent-close policies with canonical parent/child history.
- Kill before/after child creation and result propagation; no duplicate child or lost event.
- Kill before/after each compensation side effect and result commit; restart preserves reverse order and idempotency.
- Unknown event/definition versions fail explicitly; correct versions restore from snapshot plus tail.
- Feature-off compile/link validation.
- Run `zig build test-all` and `zig build test-sqlite`.

## Acceptance checklist

- [ ] Child lifecycle events have stable IDs/schema/golden data.
- [ ] Parent-child creation and notification are transactionally recoverable.
- [ ] Compensation is durable, ordered and idempotent.
- [ ] No distributed storage semantics leak into the local backend.
