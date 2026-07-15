# 17 — Workflow Frontend、Scheduler 与 Worker

## 前置

完成 05、15、16；阅读架构第 28—34、39—40、44.1、46.3、48、49.6 节。必须复用 `tests/fixtures/login_workflow.zig` 的 `game.login` v3 definition/golden，不得重写 transition。

## 目标

交付可启动、signal、poll、replay、transition、原子提交和恢复的单节点 Workflow 核心。Activity 副作用、timer scanner、retry 和 outbox publisher 归任务 18。

## 实现范围

- `workflow/client.zig`：
  - `start(definition_name, version, input, tenant, namespace, idempotency_key)`；
  - `signal(workflow_id, signal_name, payload, message_id)`；
  - `requestCancel(workflow_id, message_id)`；
  - `getInstance(workflow_id)`。
- Client 注入 `AuthHook(ctx, tenant, namespace, action, workflow_id?)`；默认生产配置必须显式提供，集成 fixture 使用 AllowAll/Deny 实现。Unauthorized 是稳定 non-retryable ErrorCode，失败事务不追加 history。
- start 单事务创建 instance、append `WorkflowStarted`、创建首个 workflow_task；相同 idempotency key 返回原 WorkflowId，冲突内容拒绝。
- start 幂等使用独立表 `workflow_start_idempotency(tenant, namespace, idempotency_key, request_hash, workflow_id)`；同 key 同 hash 返回原 ID，同 key 异 hash 返回 `IdempotencyConflict`，不复用 signal inbox。
- signal/cancel 单事务执行 tenant/namespace 授权 hook、inbox 去重、append event、确保存在可运行 workflow_task；测试禁止直接 INSERT 绕过 Client。
- `workflow/scheduler.zig`：按 namespace/definition 批量 poll/lease workflow_task；本任务不做 partition ownership。
- `workflow/worker.zig`：加载 latest snapshot + 连续 history，调用任务 15 replay verifier/transition，把 commands 规范化为 history/task/timer/activity/outbox 写集合，并只调用任务 16 的原子 `commitWorkflowTaskTransition`。
- 扩展 persistence 的真实 PostgreSQL 事务原语：`startWorkflow`、`appendSignal`、`requestCancellation`、`unblockDefinitionTasks`；逐项定义锁行、state/lease epoch、幂等键和错误分类，不重定义任务 16 已有 commit。
- `commitWorkflowTaskTransition` 的 `optional_snapshot` 承载 event_sequence、definition_version、state payload、runtime checksum；禁止提供可独立 BEGIN/COMMIT 的 snapshot 写 API，snapshot 失败使整个 transition commit 回滚。
- 追加版本化 migration：
  - workflow_instance 增 `last_processed_decision_seq` 和 `wake_requested`；
  - workflow_task 增稳定 task status、start/end decision seq、last_error_code/detail、blocked_at；
  - 对每 workflow 建「最多一条 ready/leased task」partial unique index；
  - 增上述 start idempotency 表。
- checkpoint 策略固定为：每个成功 workflow task 若距上次 snapshot ≥ 64 events，或新状态为 waiting/compensating/terminal，则在同一 commit 中写 snapshot；snapshot checksum 必须由 runtime 产生，测试不得预插入。
- Definition version 不存在/不匹配时不执行 transition、不追加 history；instance status 保持不变，workflow_task 写明确的 non-retryable blocked reason 并释放 lease，待正确版本 worker 显式重驱。
- poll loop 使用任务 04 的显式 DetachedHandle；transition/replay 在 workflow worker 专用线程同步执行，不占 compute worker，不裸建 fire-and-forget thread。
- `tests/integration/workflow_process_harness.zig` 启动独立 test worker 进程，注入 DSN/worker ID，通过控制通道设置“claim 后”“commit 前/后”故障点；crash 必须真实 kill 子进程。
- TraceContext 持久在 event envelope；重启处理保持 trace_id 并创建正确 parent span。
- `workflow/worker_runtime.zig` 交付 `start`/`shutdown(deadline)`：停止 scheduler poll、join 专用线程、收敛 DetachedHandle、不再续租；任务 18 在此基础上组合 WorkflowSubsystem，不另造 worker shutdown 语义。

## Decision Event 处理模型

- Decision event 固定为 WorkflowStarted、SignalReceived、ActivityCompleted、ActivityFailed、TimerFired、CancellationRequested、Child result；本任务执行前两类与 cancellation，其余类型供后续任务接线。
- worker 按 sequence 对 `(last_processed_decision_seq, latest_decision_seq]` 中每个 decision event逐条调用 transition；不能只处理最后一个。command/runtime 记录事件参与 replay 校验但不重复触发 transition。
- 一次 claim 可批量处理当时可见的全部 decision events并单次 commit；commit 原子更新 `last_processed_decision_seq`。
- signal/cancel 到达 leased task 时设置 `wake_requested`。commit 后若仍有未处理 decision 或 wake_requested，则保留/创建一条 ready task；进入等待 Activity/Timer/Signal 且无新 decision 时不得 busy-loop 创建下一 task。

## 事务与状态不变量

- history sequence 连续，event_id 唯一；单次 transition 的 events、instance、snapshot、衍生 task/activity/timer/outbox 要么全部提交，要么全部回滚。
- task commit 同时校验 expected_state_version 和 task lease_epoch；旧 worker 不得覆盖。
- Client start/signal/cancel 与 worker commit 并发时，只能以数据库锁/CAS 决定顺序，不靠进程 mutex。
- 本任务遇到 `start_child`/`cancel_child` command 返回明确 `UnsupportedCommand` 并保持事务回滚；任务 20 才启用。
- Workflow DB 时间只用于持久时间/lease；transition 的 logical time 只来自 history/context。
- `WorkflowTaskStatus` 使用稳定整数编码：ready=1、leased=2、completed=3、blocked=4、cancelled=5；blocked 时 lease_owner 为 NULL、lease 过期字段为 NULL，`last_error_code` 存任务 01 的稳定 ErrorCode 数值。
- worker registry 冻结/启动后调用事务原语 `unblockDefinitionTasks(definition_id, version)`，只把 reason=`DefinitionUnavailable` 且现在已有精确版本的 blocked task 改回 ready；其它 blocked reason 不自动重驱，禁止测试直接 UPDATE。

## 不做

- 不执行 Activity handler，不扫描 timer，不发布 outbox。
- 不做 partition、多进程并发 HA、Child、自动迁移、归档或 operator mutation。
- 不用 in-memory repository、假 SQL 或测试直接写 snapshot 作为验收路径。

## 验证

- 只通过 WorkflowClient 启动 login，断言 instance、连续 history、首 task 和稳定 definition version。
- duplicate start/signal/cancel；signal 与 task commit 并发；未知 definition/schema/tenant。
- worker 正常处理 WorkflowStarted/SignalReceived，输出与 login transition golden 一致；不执行其 Activity。
- 新增真实 `tests/fixtures/checkpoint_workflow.zig`（纯显式状态机）驱动 terminal/waiting 与 ≥64 events 两条 checkpoint 路径；snapshot 必须由 commit 的 optional_snapshot 产生且 checksum/replay 一致，测试不得预插入。
- 在 claim 后、commit 前、commit 后 kill 独立 worker，启动新实例后 history 无缺口/重复 command。
- snapshot + tail history、无 snapshot 全 history 两条恢复路径产生相同 state/commands。
- instance v3 而 worker 未注册 v3：task 进入稳定 blocked 状态且 history 不变；正确 v3 worker 启动后仅通过 `unblockDefinitionTasks` 重驱并完成。
- trace 跨 restart 保持 trace_id，worker span parent 链正确。
- shutdown 停止新 poll，DetachedHandle 收敛，线程 join，未完成 task lease 可由顺序启动的新实例接管。

运行 `zig build test-all` 与 `zig build test-postgres`。

## 验收清单

- [ ] Client API 是 start/signal/cancel 的唯一公开写入口。
- [ ] Workflow task 使用真实 PostgreSQL 单事务提交。
- [ ] Snapshot 由 runtime 按固定策略写入。
- [ ] 多个并发 decision event 按 sequence 恰好处理一次且不产生 busy-loop task。
- [ ] crash/restart 使用独立进程并验证数据库结果。
- [ ] 本任务未执行副作用或引入分区逻辑。
- [ ] 全量验证通过。

