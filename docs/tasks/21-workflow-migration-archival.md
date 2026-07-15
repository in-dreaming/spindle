# 21 - Workflow Migration, Archival, Security and Operator API

## Prerequisites

Complete 20 and 14. Artifact archival is optional and must respect feature boundaries.

## Goal

Deliver explicit definition migration, bounded local history archival and authorized operator controls for the SQLite Workflow backend.

## Migration and operator behavior

- Add stable `DefinitionMigrated` and `WorkflowTerminated` events with version/hash/principal/reason fields and schema golden data.
- Migration waits for or fences claimed work, loads and validates state, calls the pure task 15 migration function, then appends the marker, changes definition version and writes a snapshot in one SQLite transaction.
- Signals accepted during migration remain ordered and wake the new definition only after successful migration. Failure rolls back and leaves the old version authoritative.
- Operator API provides inspect/history/pending, cancel/retry, terminate and migrate with viewer/operator/admin authorization.
- Every mutation requires principal, reason and idempotency key and records an audit row transactionally. Unauthorized attempts are also audited without exposing sensitive payloads.
- Enforce tenant/namespace isolation, quotas, schema allowlists and payload/replay limits.

## Archival boundary

- Keep recent history and all discovery metadata in SQLite. Archive only completed workflows older than configured retention.
- The archive codec is stable, chunked and checksummed. Write, read back and verify an archive before atomically recording its manifest and deleting covered hot rows.
- `-Dworkflow-archive=true` implies workflow-sqlite and provides the local filesystem ArtifactStore.
- `-Dworkflow-archive-http=true` implies workflow-archive and resource-graph and enables the task 14 HTTP ArtifactStore adapter. Workflow core and SQLite persistence cannot import it directly.
- History reader composes archive plus hot tail and verifies continuous sequence/checksums before replay.
- SQLite backup from task 19 is operational backup, not history archival; keep the contracts distinct.

## Non-goals

- No PostgreSQL, remote mandatory object store, distributed migration lease, partition epoch, multi-region storage or transparent encryption implementation.

## Verification

- Successful/failed migration, concurrent signal, stale runtime commit and restart at every migration boundary.
- Archive interruption before/after write, verification, manifest commit and hot deletion; at least one complete history always remains.
- Archive plus hot-tail replay equals pre-archive canonical state/commands.
- Authorization matrix, cross-tenant denial, quotas, idempotent operator mutation and sensitive-data redaction.
- Feature matrix proves HTTP/Resource Graph/archive adapters are absent unless enabled.
- Run `zig build test-all` and `zig build test-sqlite`.

## Acceptance checklist

- [ ] Definition switch is explicit, atomic and replay-safe.
- [ ] Archival cannot lose the only valid history.
- [ ] Operator mutations are authorized, idempotent and audited.
- [ ] Optional archive transports impose zero disabled-build dependency cost.
