CREATE TABLE workflow_child (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL,
    parent_workflow_id BLOB NOT NULL CHECK(length(parent_workflow_id)=16),
    child_workflow_id BLOB NOT NULL CHECK(length(child_workflow_id)=16),
    parent_close_policy INTEGER NOT NULL CHECK(parent_close_policy IN (1,2,3)),
    notification_status TEXT NOT NULL DEFAULT 'pending' CHECK(notification_status IN ('pending','completed','failed','cancelled')),
    PRIMARY KEY(tenant,namespace,parent_workflow_id,child_workflow_id),
    UNIQUE(tenant,namespace,child_workflow_id),
    FOREIGN KEY(tenant,namespace,parent_workflow_id) REFERENCES workflow_instance(tenant,namespace,workflow_id),
    FOREIGN KEY(tenant,namespace,child_workflow_id) REFERENCES workflow_instance(tenant,namespace,workflow_id)
) STRICT;
CREATE TABLE compensation_plan (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL, workflow_id BLOB NOT NULL CHECK(length(workflow_id)=16),
    plan_id BLOB NOT NULL CHECK(length(plan_id)=16), status TEXT NOT NULL CHECK(status IN ('running','completed','failed')),
    PRIMARY KEY(tenant,namespace,plan_id), FOREIGN KEY(tenant,namespace,workflow_id) REFERENCES workflow_instance(tenant,namespace,workflow_id)
) STRICT;
CREATE TABLE compensation_step (
    tenant TEXT NOT NULL, namespace TEXT NOT NULL, plan_id BLOB NOT NULL CHECK(length(plan_id)=16),
    step_index INTEGER NOT NULL CHECK(step_index>=0), activity_type INTEGER NOT NULL,
    schema_id INTEGER NOT NULL, schema_version INTEGER NOT NULL, input_hash INTEGER NOT NULL,
    payload BLOB NOT NULL CHECK(length(payload)<=1048576), status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed')),
    PRIMARY KEY(tenant,namespace,plan_id,step_index), FOREIGN KEY(tenant,namespace,plan_id) REFERENCES compensation_plan(tenant,namespace,plan_id)
) STRICT;
