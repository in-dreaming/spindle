ALTER TABLE workflow_instance ADD COLUMN migration_state TEXT NOT NULL DEFAULT 'idle' CHECK(migration_state IN ('idle','migrating'));

CREATE TABLE workflow_operator_audit (
    audit_id INTEGER PRIMARY KEY,
    tenant TEXT NOT NULL,
    namespace TEXT NOT NULL,
    workflow_id BLOB CHECK(workflow_id IS NULL OR length(workflow_id)=16),
    principal TEXT NOT NULL,
    action TEXT NOT NULL,
    reason TEXT NOT NULL,
    idempotency_key TEXT NOT NULL,
    authorized INTEGER NOT NULL CHECK(authorized IN (0,1)),
    request_hash INTEGER NOT NULL,
    created_utc_ms INTEGER NOT NULL,
    UNIQUE(tenant,namespace,principal,action,idempotency_key)
) STRICT;

CREATE TABLE workflow_history_archive (
    tenant TEXT NOT NULL,
    namespace TEXT NOT NULL,
    workflow_id BLOB NOT NULL CHECK(length(workflow_id)=16),
    first_sequence INTEGER NOT NULL CHECK(first_sequence>0),
    last_sequence INTEGER NOT NULL CHECK(last_sequence>=first_sequence),
    location TEXT NOT NULL,
    checksum INTEGER NOT NULL,
    event_count INTEGER NOT NULL CHECK(event_count>0),
    created_utc_ms INTEGER NOT NULL,
    PRIMARY KEY(tenant,namespace,workflow_id,first_sequence),
    FOREIGN KEY(tenant,namespace,workflow_id) REFERENCES workflow_instance(tenant,namespace,workflow_id)
) STRICT;
