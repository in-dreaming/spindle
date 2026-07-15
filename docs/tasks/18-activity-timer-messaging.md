# 18 — Activity、Retry、Durable Timer 与可靠消息

## 前置

完成 17；阅读架构第 30、34.4—38、44.5、48、49.6 节。登录验收继续复用 `tests/fixtures/login_workflow.zig` 的场景和 golden。

## 目标

在单节点 Workflow worker 上完成真实副作用执行、幂等、heartbeat/timeout/retry、持久 timer、inbox/outbox，并端到端跑通登录、重连和补偿。

## 实现范围

- 扩展 `workflow/event.zig` 与 schema golden，新增稳定 `ActivityAttemptFailed` event kind；包含 ActivityKey、attempt、FailureClass、ErrorCode、backoff_ms，供 replay/审计，不触发 workflow transition。
- `workflow/activity_registry.zig`：activity type → handler/schema/idempotency class/allowed executor；生产注册只接受 `idempotency_required`，测试不得注册 unsafe handler绕过。
- `workflow/activity_worker.zig`：批量 poll/lease、schedule-to-start、执行、heartbeat、start-to-close、完成/失败；阻塞 RPC/DB/file 走 BlockingExecutor，CPU handler 可走 ComputeExecutor。
- `ActivityContext` 提供 ActivityKey、attempt、deadline、CancellationToken、trace 和 heartbeat；不得暴露 workflow state 的可变引用。
- persistence 新增并在 PostgreSQL 实现以下单事务原语：
  - `commitActivityCompletion`：校验 activity lease epoch，完成 task，append result event，wake workflow；同 activity_id/attempt/payload 重放返回 IdempotentSuccess，不追加第二 event，不同 payload 返回协议错误；
  - `rescheduleActivityAttempt`：retryable 且未耗尽时，完成当前 attempt，append `ActivityAttemptFailed`（attempt/failure/backoff），以相同 ActivityKey/command_sequence 创建 attempt+1，禁止 wake workflow；
  - `commitActivityTerminalFailure`：重试耗尽或 non-retryable 时 append `ActivityFailed` 并 wake workflow；
  - `recordActivityHeartbeat`：CAS 当前 attempt/epoch，并按 policy 更新 lease_expire_at/heartbeat_deadline；旧 epoch/attempt 明确失败；
  - `fireDueTimer`：claim + 标记 fired + append `TimerFired` + wake workflow；
  - `cancelTimer`：原子标 cancelled，已 cancelled timer 不可再 claim/fire；
  - `claimOutbox`/`markOutboxSent`，以及接收端 inbox 去重。
- 追加版本化 migration：durable_timer 增 lease_owner/lease_epoch/lease_expire_at 和唯一逻辑 fire event ID；outbox 增 attempt/available_at/lease 字段；所有 completion/fire/mark 操作校验对应 epoch，过期 claimant 不能覆盖。
- `workflow/timer.zig`：PostgreSQL `fire_at_utc_ms` 为事实来源，DB server time、索引、批量 `SKIP LOCKED`；内存 heap 只能加速。
- `workflow/retry.zig` 接线任务 15 policy：schedule-to-start、start-to-close、heartbeat、workflow execution/idle、signal wait timeout均落为持久 event/timer，不依赖进程 sleep。
- `workflow/outbox.zig`：有界 publisher、发送后标记、失败重试；真实 loopback HTTP server 持久记录 message_id/body，接收事务用 inbox 去重。
- `tests/fixtures/login_activity_store.sql` 创建真实业务结果表：ActivityKey 主键、result payload、side_effect_marker 唯一；测试 handler 的副作用和幂等结果同一业务事务。
- 扩展任务 17 process harness，支持 Activity 执行后/业务 commit 后/workflow result commit 前、timer claim 后、outbox send 后等精确 kill 点。
- `WorkflowSubsystem.shutdown`：停止 poll；短 activity 收敛，长 activity heartbeat 后释放/等待 lease；timer/outbox 停止 claim，全部 DetachedHandle join。任务 22 的全局 Runtime 只调用该既定接口。
- `WorkflowSubsystem.init/start` 组合任务 17 worker runtime、activity worker、timer scanner、outbox publisher，所有 loop 使用 DetachedHandle；启动失败逆序清理。shutdown 顺序固定为停止新 claim → workflow/activity 收敛 → timer/outbox → join。

## Timeout 分层

- Schedule-to-Start：activity scanner 根据未 claim task 和 DB time 检测，走 reschedule/terminal failure。
- Start-to-Close：activity worker 根据 attempt start 与 deadline 检测，走 reschedule/terminal failure。
- Heartbeat：activity scanner 根据 heartbeat_deadline 检测，走 reschedule/terminal failure。
- Signal Wait：transition 创建 durable_timer，scanner 通过 fireDueTimer 产生 TimerFired 并唤醒 workflow。
- Workflow Execution：Client start 时创建持久 timer，到期产生规范 timeout event/终态。
- Workflow Idle：进入 waiting 时刷新持久 timer，到期产生 TimerFired 并唤醒 workflow。

前三类 Activity timeout 不产生 TimerFired，也不让 transition 重新 schedule Activity；后三类由 durable timer 驱动。

## 登录固定场景

1. normal：authenticate → load account → `client.role_selected` signal → allocate → create session → notify → ack signal → complete。
2. reconnect：停在 waiting_client_ack，`client.reconnected` signal 只重发已有 SessionInfo，不创建第二 Session。
3. ack timeout：revoke session → release allocation，顺序严格。
4. create session 失败：release allocation。
5. retryable auth failure：按 policy 重试后成功；business rejection 不重试。
6. duplicate Activity result/signal/outbox：history 与外部副作用保持幂等。

本任务的补偿仅由 login transition 发出普通幂等 Activity，不实现通用 compensation stack/operator 重驱（任务 20）。

`tests/fixtures/login_workflow.zig` 追加每场景 runtime-history golden：在任务 15 transition command golden 之外，明确插入 ActivityStarted/Heartbeat/ActivityAttemptFailed/TimerFired 等运行时事件。transition golden 不变，禁止删除运行时事件来迎合旧 golden。

notify 固定为幂等 Activity；notifying_client transition 同时按规范 command→outbox 映射写消息，message_id 来自 workflow_id + command_sequence。场景 6 必须在完整 login 路径验证 outbox，不允许孤立 publisher 单测替代。

Workflow signal inbox 继续使用任务 17 的 workflow inbox；loopback receiver 使用独立 `outbox_receiver_inbox` 测试业务表，receiver inbox 与接收副作用同一 PostgreSQL transaction，禁止复用 workflow inbox。

## 验证

- 前三类 Activity timeout 与后三类 Workflow timeout分别独立断言；execution/idle 各有非 login PostgreSQL harness，六类均检查持久载体、event、attempt和最终状态。
- 业务 kill 点（Activity 执行后、业务 commit 后、result commit 前）：side_effect_marker 恰好一行且 workflow 一个逻辑 result。
- timer claim/fire commit 前后 kill：最终一个 TimerFired；outbox send 后/mark 前 kill：物理发送可重复但 receiver 处理一次。
- 多 scanner 竞争、scanner crash、重复扫描同 timer，最终只有一个 `TimerFired` event。
- outbox send 后未 mark 导致物理重复发送；接收端 body/message_id 一致且 inbox 只处理一次；mark 后不再发送。
- 六个 login 场景分别断言 transition golden 与 runtime-history golden，instance status/state_version、history sequence、终态无 pending activity/timer；normal ack 后 timer 必须 cancelled 且永不 fire。
- workflow/activity trace 同 trace_id，activity parent 指向 workflow；restart 后关联不丢。
- shutdown 后无新 claim、线程 join，顺序启动的新实例可接管过期 lease。

运行 `zig build test-all` 与 `zig build test-postgres`。

## 验收清单

- [ ] 副作用只在 Activity，且全部验收 handler 具备真实幂等存储。
- [ ] Activity/timer/result 写入均为带 epoch 的真实单事务。
- [ ] 六类 timeout/retry 有持久状态与确定性测试。
- [ ] timer/outbox crash 测试使用真实 DB、进程和 loopback 网络。
- [ ] 登录六场景无第二套 transition/golden。
- [ ] 全量验证通过。

