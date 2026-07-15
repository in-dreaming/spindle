CREATE TABLE IF NOT EXISTS spindle_schema_migration (
    version bigint PRIMARY KEY,
    checksum text NOT NULL,
    applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
);

CREATE TABLE workflow_instance (
    tenant text NOT NULL,
    namespace text NOT NULL,
    workflow_id uuid NOT NULL,
    definition_id bigint NOT NULL,
    definition_version integer NOT NULL CHECK (definition_version > 0),
    status text NOT NULL CHECK (status IN ('running', 'completed', 'failed', 'cancelled')),
    state bytea NOT NULL,
    state_version bigint NOT NULL CHECK (state_version >= 0),
    next_sequence bigint NOT NULL CHECK (next_sequence >= 1),
    owner_epoch bigint NOT NULL DEFAULT 0 CHECK (owner_epoch = 0),
    created_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    updated_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant, namespace, workflow_id)
);

CREATE TABLE workflow_history (
    tenant text NOT NULL, namespace text NOT NULL, workflow_id uuid NOT NULL,
    sequence bigint NOT NULL CHECK (sequence > 0), event_id uuid NOT NULL,
    kind integer NOT NULL, event_utc_ms bigint NOT NULL, schema_id bigint NOT NULL,
    schema_version integer NOT NULL, payload bytea NOT NULL,
    PRIMARY KEY (tenant, namespace, workflow_id, sequence),
    UNIQUE (event_id),
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);

CREATE TABLE workflow_task (
    task_id uuid PRIMARY KEY, tenant text NOT NULL, namespace text NOT NULL, workflow_id uuid NOT NULL,
    status text NOT NULL CHECK (status IN ('ready', 'leased', 'done')) DEFAULT 'ready',
    available_at timestamptz NOT NULL DEFAULT clock_timestamp(), lease_owner text,
    lease_epoch bigint NOT NULL DEFAULT 0, lease_expires_at timestamptz,
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);
CREATE INDEX workflow_task_claim_idx ON workflow_task (tenant, namespace, available_at) WHERE status = 'ready';
CREATE INDEX workflow_task_expiry_idx ON workflow_task (lease_expires_at) WHERE status = 'leased';

CREATE TABLE activity_task (
    task_id uuid PRIMARY KEY, tenant text NOT NULL, namespace text NOT NULL, workflow_id uuid NOT NULL,
    command_sequence bigint NOT NULL, payload bytea NOT NULL, status text NOT NULL DEFAULT 'ready',
    available_at timestamptz NOT NULL DEFAULT clock_timestamp(), lease_owner text, lease_epoch bigint NOT NULL DEFAULT 0, lease_expires_at timestamptz,
    UNIQUE (tenant, namespace, workflow_id, command_sequence),
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);
CREATE INDEX activity_task_claim_idx ON activity_task (available_at) WHERE status = 'ready';

CREATE TABLE durable_timer (
    timer_id uuid PRIMARY KEY, tenant text NOT NULL, namespace text NOT NULL, workflow_id uuid NOT NULL,
    fire_at_utc_ms bigint NOT NULL, payload bytea NOT NULL, status text NOT NULL DEFAULT 'ready',
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);
CREATE INDEX durable_timer_due_idx ON durable_timer (fire_at_utc_ms) WHERE status = 'ready';

CREATE TABLE workflow_snapshot (
    tenant text NOT NULL, namespace text NOT NULL, workflow_id uuid NOT NULL, event_sequence bigint NOT NULL,
    definition_version integer NOT NULL, state bytea NOT NULL, checksum bigint NOT NULL,
    PRIMARY KEY (tenant, namespace, workflow_id, event_sequence),
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);
CREATE TABLE inbox (
    tenant text NOT NULL, namespace text NOT NULL, message_id uuid NOT NULL, workflow_id uuid NOT NULL,
    payload bytea NOT NULL, received_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    PRIMARY KEY (tenant, namespace, message_id),
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);
CREATE TABLE outbox (
    message_id uuid PRIMARY KEY, tenant text NOT NULL, namespace text NOT NULL, workflow_id uuid NOT NULL,
    payload bytea NOT NULL, available_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    lease_owner text, lease_epoch bigint NOT NULL DEFAULT 0, lease_expires_at timestamptz, published_at timestamptz,
    FOREIGN KEY (tenant, namespace, workflow_id) REFERENCES workflow_instance (tenant, namespace, workflow_id)
);
CREATE INDEX outbox_claim_idx ON outbox (available_at) WHERE published_at IS NULL;
