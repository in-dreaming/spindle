# 20 — Child Workflow 与通用补偿

## 前置

完成 19；阅读架构第 29.4、32、38.4、51 Phase 9 节。

## 目标

在稳定双 epoch runtime 上实现 Child Workflow 完整生命周期和可恢复 compensation plan，不把跨服务失败伪装成数据库回滚。

## 协议扩展

扩展 `workflow/event.zig` 与 schema golden，分配稳定 event kind ID：

- ChildWorkflowStarted/Completed/Failed/Cancelled；
- WorkflowTerminated；
- CompensationPlanCreated；
- CompensationStepScheduled/Completed/Failed。

更新任务 15 replay verifier 和 event golden；未知旧 worker 遇到新 kind 必须明确版本不兼容，不可跳过。Command 中已有 start_child/cancel_child 从本任务起启用。

## 实现范围

- `workflow/child.zig`：parent-child 关联、start/cancel、结果回传、幂等 command sequence。
- 新增持久表/约束记录 parent_id、child_id、command_sequence、parent_close_policy；创建 child instance、parent history 和关联必须处于可恢复事务边界。
- `ParentClosePolicy` 稳定编码：
  - `abandon`：child 独立继续；
  - `request_cancel`：幂等写 child CancellationRequested；
  - `terminate`：写 WorkflowTerminated，区别于普通 cancel，且不运行 child 清理逻辑。
- `workflow/compensation.zig`：持久 CompensationPlan，由有序 step 构成（activity type/schema/input hash/index/status）；每 step 是任务 18 的幂等 Activity。
- compensation 按逆业务提交顺序执行；单步失败可按 policy retry，耗尽后实例进入既有 `failed` 状态且 plan 标记 `failed` 并记录具体 step，不能静默标 completed。
- login 的 revoke session → release allocation 改为两步 plan 的正式 fixture，保持任务 18 已验收顺序与 ActivityKey 幂等。
- parent/child/compensation 的 workflow task 仍受任务 19 双 epoch fencing。
- fixture 固定为 `tests/fixtures/child_parent_workflow.zig` 和已有 login fixture，不在测试内临时生成 transition。

## 关键语义

- Child 是独立 WorkflowId、history、snapshot、lease；parent 只通过持久 event 获取结果。
- parent start-child command 重放不得创建第二 child。
- parent terminal 与 child terminal 并发时由唯一约束和 event_id 去重收敛。
- terminate event 必须真实携带非空 principal/reason；授权与审计落库由任务 21 完成，本任务测试使用明确的内部 system principal。
- compensation 是正向幂等 Activity 序列，不撤销已提交数据库历史。

## 验证

- child start/complete/fail/cancel 的完整 parent/child history golden。
- 三种 parent-close policy，覆盖 parent/child terminal 并发。
- 在 child 创建事务前后、结果回传前后 kill owner 并故障转移，无 orphan duplicate 或漏 event。
- compensation 每步前/业务 commit 后/result commit 前 kill；重启后顺序正确且每个副作用一次。
- compensation retryable/non-retryable/耗尽、operator 尚不可重驱时保持可诊断状态。
- 旧 definition/replay verifier 遇到新 event 明确失败；正确版本可从 snapshot+tail 恢复。

运行 `zig build test-all` 与 `zig build test-postgres`。

## 验收清单

- [ ] Child 全生命周期事件有稳定 ID/schema/golden。
- [ ] ParentClosePolicy 三种行为与 crash matrix 全覆盖。
- [ ] compensation plan 持久、可恢复且副作用幂等。
- [ ] login 补偿复用正式 plan，无第二套逻辑。
- [ ] 全量验证通过。

