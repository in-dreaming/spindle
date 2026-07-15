CREATE TABLE metadata (
    key TEXT PRIMARY KEY,
    value INTEGER NOT NULL
) STRICT;

CREATE TABLE workflow_instance (
    tenant TEXT NOT NULL,
    namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    definition_id INTEGER NOT NULL,
    definition_version INTEGER NOT NULL CHECK(definition_version > 0),
    status TEXT NOT NULL CHECK(status IN ('running','completed','failed','cancelled')),
    state BLOB NOT NULL CHECK(length(state) <= 1048576),
    state_version INTEGER NOT NULL DEFAULT 0 CHECK(state_version >= 0),
    next_sequence INTEGER NOT NULL DEFAULT 1 CHECK(next_sequence >= 1),
    last_processed_decision_seq INTEGER NOT NULL DEFAULT 0 CHECK(last_processed_decision_seq >= 0),
    created_utc_ms INTEGER NOT NULL,
    updated_utc_ms INTEGER NOT NULL,
    PRIMARY KEY(tenant, namespace, workflow_id)
) STRICT;

CREATE TABLE workflow_history (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    sequence INTEGER NOT NULL CHECK(sequence > 0),
    event_id BLOB NOT NULL UNIQUE CHECK(length(event_id) = 16),
    kind INTEGER NOT NULL, event_utc_ms INTEGER NOT NULL,
    schema_id INTEGER NOT NULL, schema_version INTEGER NOT NULL CHECK(schema_version > 0),
    payload BLOB NOT NULL CHECK(length(payload) <= 1048576),
    PRIMARY KEY(tenant, namespace, workflow_id, sequence),
    FOREIGN KEY(tenant, namespace, workflow_id)
        REFERENCES workflow_instance(tenant, namespace, workflow_id)
) STRICT;

CREATE TABLE workflow_task (
    task_id BLOB PRIMARY KEY CHECK(length(task_id) = 16),
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    status TEXT NOT NULL CHECK(status IN ('ready','claimed','completed','blocked')),
    available_utc_ms INTEGER NOT NULL,
    claimed_epoch INTEGER,
    blocked_definition_id INTEGER,
    blocked_definition_version INTEGER,
    FOREIGN KEY(tenant, namespace, workflow_id)
        REFERENCES workflow_instance(tenant, namespace, workflow_id)
) STRICT;
CREATE INDEX workflow_task_ready_idx ON workflow_task(status, available_utc_ms, task_id);
CREATE UNIQUE INDEX workflow_task_one_active_idx
    ON workflow_task(tenant, namespace, workflow_id)
    WHERE status IN ('ready','claimed');

CREATE TABLE activity_task (
    task_id BLOB PRIMARY KEY CHECK(length(task_id) = 16),
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    command_sequence INTEGER NOT NULL,
    payload BLOB NOT NULL CHECK(length(payload) <= 1048576),
    status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','completed')),
    UNIQUE(tenant, namespace, workflow_id, command_sequence)
) STRICT;

CREATE TABLE durable_timer (
    timer_id BLOB PRIMARY KEY CHECK(length(timer_id) = 16),
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    fire_at_utc_ms INTEGER NOT NULL,
    payload BLOB NOT NULL CHECK(length(payload) <= 1048576),
    status TEXT NOT NULL DEFAULT 'ready' CHECK(status IN ('ready','completed'))
) STRICT;
CREATE INDEX durable_timer_due_idx ON durable_timer(status, fire_at_utc_ms);

CREATE TABLE workflow_snapshot (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    event_sequence INTEGER NOT NULL,
    definition_version INTEGER NOT NULL,
    state BLOB NOT NULL CHECK(length(state) <= 1048576),
    checksum INTEGER NOT NULL,
    PRIMARY KEY(tenant, namespace, workflow_id, event_sequence)
) STRICT;

CREATE TABLE inbox (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    message_id BLOB NOT NULL CHECK(length(message_id) = 16),
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    event_sequence INTEGER,
    payload BLOB NOT NULL CHECK(length(payload) <= 1048576),
    PRIMARY KEY(tenant, namespace, message_id)
) STRICT;

CREATE TABLE outbox (
    message_id BLOB PRIMARY KEY CHECK(length(message_id) = 16),
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    payload BLOB NOT NULL CHECK(length(payload) <= 1048576),
    published_utc_ms INTEGER
) STRICT;
CREATE INDEX outbox_unpublished_idx ON outbox(message_id) WHERE published_utc_ms IS NULL;

CREATE TABLE workflow_start_idempotency (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    request_hash INTEGER NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id) = 16),
    PRIMARY KEY(tenant, namespace, idempotency_key)
) STRICT;
