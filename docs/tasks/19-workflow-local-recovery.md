# 19 - Workflow Local Recovery, Integrity and Maintenance

## Prerequisites

Complete 18. Read architecture sections 33, 35, 40, 48 and 49.6. This task strengthens the single-machine SQLite backend; it does not introduce a distributed scheduler.

## Goal

Make an embedded Workflow store operable for long-running desktop/server processes: deterministic startup recovery, integrity verification, online backup, bounded maintenance and clear corruption diagnostics.

## Implementation scope

- Harden task 17's startup recovery transaction: increment `runtime_epoch`, invalidate stale claims, requeue recoverable workflow/activity/outbox work and leave terminal/blocked work unchanged.
- Persist clean/unclean shutdown metadata. Correctness must not rely on a clean marker, but diagnostics report the previous exit state.
- Add `workflow/store_health.zig`: schema version, migration hashes, `PRAGMA quick_check`/targeted invariants, history continuity, snapshot checksums, orphan task detection and bounded repair classification.
- Automatic repair is limited to derivable queue/index state. Never synthesize history, delete unknown data or rewrite state payloads.
- Add online backup through SQLite's supported backup mechanism to a caller-provided local path, followed by opening and validating the backup before success.
- Restore is an explicit offline operation: validate source, replace through same-filesystem atomic rename, reopen, increment epoch and verify. Preserve the failed database for diagnosis.
- Add bounded checkpoint/compaction policy. WAL checkpoint and vacuum decisions expose progress/cancellation and never run on executor compute workers.
- Database-full, read-only, corrupt page, interrupted backup and process kill during maintenance have stable error/reporting behavior.
- Metrics expose database bytes, WAL bytes, pending work, last checkpoint, recovery counts and integrity status without leaking payloads.

## Feature boundary

- All code remains under `-Dworkflow-sqlite=true`.
- Workflow core-only builds must not import maintenance or filesystem persistence code.
- Backup support uses the existing filesystem/I/O abstractions; it must not require HTTP, ArtifactStore or Resource Graph.

## Non-goals

- No partition ownership, distributed lease, leader election, multi-process HA, replication, remote database or Docker.
- No automatic salvage of corrupted history and no cloud backup provider.

## Verification

- Kill at each startup recovery/backup/checkpoint/restore boundary and reopen from a new process.
- Verify stale claims are recovered once and committed work is never replayed as pending.
- Detect sequence gaps, checksum mismatch, orphan records, modified migrations and corrupt database pages.
- Backup while reads/writes are active; restored canonical state equals source at the documented snapshot point.
- Feature-off compilation/link inspection.
- Run `zig build test-all` and `zig build test-sqlite`.

## Acceptance checklist

- [ ] Recovery is deterministic and fenced by runtime epoch.
- [ ] Integrity checks diagnose without inventing state.
- [ ] Backup/restore survives real process interruption.
- [ ] Maintenance is bounded, cancellable and isolated from compute workers.
- [ ] No distributed or external-service dependency is introduced.
