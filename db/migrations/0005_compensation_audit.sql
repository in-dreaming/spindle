ALTER TABLE activity_task ADD COLUMN compensation_plan_id BLOB CHECK(compensation_plan_id IS NULL OR length(compensation_plan_id)=16);
ALTER TABLE activity_task ADD COLUMN compensation_step_index INTEGER CHECK(compensation_step_index IS NULL OR compensation_step_index>=0);
ALTER TABLE compensation_step ADD COLUMN task_id BLOB CHECK(task_id IS NULL OR length(task_id)=16);
ALTER TABLE compensation_step ADD COLUMN command_sequence INTEGER;

UPDATE compensation_step AS step
SET task_id=(
        SELECT task.task_id FROM activity_task AS task
        JOIN compensation_plan AS plan
          ON plan.tenant=step.tenant AND plan.namespace=step.namespace AND plan.plan_id=step.plan_id
        WHERE task.tenant=step.tenant AND task.namespace=step.namespace
          AND task.workflow_id=plan.workflow_id AND task.payload=step.payload
          AND task.schema_id=step.schema_id AND task.schema_version=step.schema_version
        ORDER BY task.command_sequence DESC LIMIT 1
    ),
    command_sequence=(
        SELECT task.command_sequence FROM activity_task AS task
        JOIN compensation_plan AS plan
          ON plan.tenant=step.tenant AND plan.namespace=step.namespace AND plan.plan_id=step.plan_id
        WHERE task.tenant=step.tenant AND task.namespace=step.namespace
          AND task.workflow_id=plan.workflow_id AND task.payload=step.payload
          AND task.schema_id=step.schema_id AND task.schema_version=step.schema_version
        ORDER BY task.command_sequence DESC LIMIT 1
    );

UPDATE activity_task AS task
SET compensation_plan_id=(SELECT step.plan_id FROM compensation_step AS step WHERE step.task_id=task.task_id),
    compensation_step_index=(SELECT step.step_index FROM compensation_step AS step WHERE step.task_id=task.task_id)
WHERE EXISTS(SELECT 1 FROM compensation_step AS step WHERE step.task_id=task.task_id);

UPDATE activity_task AS task
SET status_v2='completed', claimed_epoch=NULL
WHERE compensation_plan_id IS NOT NULL AND status_v2 IN ('ready','claimed')
  AND compensation_step_index<>(
      SELECT max(step.step_index) FROM compensation_step AS step
      WHERE step.tenant=task.tenant AND step.namespace=task.namespace
        AND step.plan_id=task.compensation_plan_id AND step.status IN ('pending','running')
  );

CREATE UNIQUE INDEX activity_compensation_active
ON activity_task(tenant,namespace,compensation_plan_id)
WHERE compensation_plan_id IS NOT NULL AND status_v2 IN ('ready','claimed');

ALTER TABLE workflow_operator_audit ADD COLUMN result TEXT NOT NULL DEFAULT 'pending'
CHECK(result IN ('pending','succeeded','failed'));
ALTER TABLE workflow_operator_audit ADD COLUMN error TEXT;

UPDATE workflow_operator_audit
SET result=CASE WHEN authorized=1 THEN 'succeeded' ELSE 'failed' END,
    error=CASE WHEN authorized=0 THEN 'Unauthorized' ELSE NULL END;
