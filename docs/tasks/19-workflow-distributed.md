# 19 — Workflow 分区、双 Epoch 与多进程 HA

## 前置

完成 18；阅读架构第 29、33、34、35、49.6、51 Phase 9 节。本任务只做分区 ownership 和故障转移，不夹带 Child、迁移、归档。

## 目标

把单节点 runtime 扩展为 PostgreSQL 协调的多进程部署，以 partition owner epoch + task lease epoch 双重 fencing 防止 split-brain commit。

## 数据模型

新增版本化 migration：

```text
workflow_partition_config(
  config_id PK, partition_count, hash_version, created_at
)
workflow_partition_lease(
  partition_id PK, owner_id NULL, owner_epoch,
  lease_expire_at, updated_at
)
```

- `stableHashV1` 固定为 BLAKE3(`"spindle.workflow.partition.v1"` || StableId 16-byte big-endian) digest 的前 8 字节按 big-endian u64 解释；`partition_id = hash % partition_count`。hash golden 跨进程/平台一致。
- `workflow_partition_config` 是单例行（`config_id = 1` CHECK）；已创建 config 的 `partition_count/hash_version` 不可原地修改。reshard 不在本任务，配置不一致拒绝启动。
- task lease epoch 是任务 16 的单次 claim fencing。
- partition owner epoch 是分区进程 ownership fencing。
- `workflow_instance.owner_epoch` 记录最后成功 commit 使用的 partition epoch；每次 commit 同时校验 task epoch、partition owner/epoch/未过期，并 CAS 更新 instance owner_epoch。
- 上述三项必须在同一 PostgreSQL transaction 内通过锁行/条件 UPDATE 与 `CURRENT_TIMESTAMP` 判定；禁止先 SELECT 到客户端再无条件写。
- migration 为 workflow_instance、workflow_task、activity_task、durable_timer、outbox 增加非空 partition_id；先以同一 stableHashV1 在 migration runner 中回填存量行，再给 instance 建 `(workflow_id, partition_id)` UNIQUE、给衍生表建对应复合外键，最后设 NOT NULL。空库和有存量 workflow 两条升级路径都必须测试。
- migration 只创建 schema；显式 `workflow partition init --count N` 在单 transaction 插入单例 config 并预建 `[0,N)` 全部 lease 行（owner NULL、epoch 0），重复执行仅在 count/hash_version 完全一致时成功。partition_id 另有外键指向 lease 表以保证范围合法。PostgreSQL 不复刻 BLAKE3，mapping 一致性由所有 Zig 写路径、worker load 校验和 golden 保证。

## 实现范围

- `workflow/partition.zig`：claim、renew、release、丢失检测、稳定 mapping。
- 扩展 `workflow/persistence.zig`/`postgres.zig`：
  - `commitWorkflowTaskTransition` 增 worker_id + partition epoch 并执行下述规范 fencing；
  - start/signal/cancel/activity completion/failure/timer fire 的 wake 写入从锁定 instance 复制 partition_id，不校验 partition epoch；
  - scheduler/worker 增 partition filter 和 ownership-lost 停止逻辑。
- scheduler 仅 poll 当前进程拥有分区的 workflow_task；ownership 丢失立即停止新 claim。
- 优雅移交：旧 owner 停止 poll；在途 commit 只有双 epoch 仍有效才可成功；新 owner 从 snapshot+history 恢复，不传内存状态。
- WorkflowClient.start 计算并写 instance/首 task partition_id；任务 17/18 的所有衍生 task/timer/activity/outbox 原语必须从锁定的 instance 复制 partition_id，不接受调用方任意传值。
- worker claim 后重新计算 instance mapping；不一致时将 task 置为持久 quarantine/blocked 诊断状态，不在错误分区执行。
- Timer scanner、Activity worker、Outbox publisher可全局 `SKIP LOCKED`。Signal/Activity result/TimerFired 是外部输入 append：分别以 message_id、activity lease_epoch、timer lease_epoch 幂等，并锁定 instance 分配连续 sequence；它们不要求 partition owner epoch，但只能创建带正确 partition_id 的 ready task。只有执行 transition 并改变 workflow state/commands 的 `commitWorkflowTaskTransition` 必须校验双 epoch。
- namespace/activity type 并发限额和有界 poll batch，背压只减少 claim，不丢任务。
- `tests/integration/workflow_ha_harness.zig` 启动至少两个独立 worker 进程，各有唯一 worker ID、同一真实 PostgreSQL、可控制 pause/SIGKILL/restart/连接断开。
- metrics/trace：ownership change、renew failure、lease expired、fence rejection、claim latency。

## Partition Claim 与 Commit 规范

- worker 启动读取已初始化 config；缺失 config、不支持的 hash_version、配置 count 不匹配均拒绝启动。HA 单分区测试用 N=1，多分区测试用 N≥4。
- claim 使用单条条件 UPDATE：仅 owner NULL 或 lease_expire_at <= DB CURRENT_TIMESTAMP 时将 owner_id 设为当前 worker、owner_epoch+1并设置 expiry；renew 同时匹配 owner_id/epoch。
- `commitWorkflowTaskTransition` 在同一 transaction 依固定顺序锁定 instance、task、partition lease，并校验：
  1. task lease_owner/lease_epoch/lease_expire_at；
  2. partition owner_id 等于 worker、owner_epoch 等于提交 epoch、lease_expire_at > DB CURRENT_TIMESTAMP；
  3. instance state_version 等于 expected。
- fencing 权威源仅是 partition lease 行；instance.owner_epoch 是记录字段。failover 后新 owner 首笔 commit 允许旧 instance.owner_epoch 小于新 epoch，并在成功 CAS 时更新。
- 失败必须区分 TaskLeaseFenceRejected、PartitionLeaseFenceRejected、StateVersionConflict。

## 关键语义

- DB server time 是 ownership lease 唯一时间源。
- 同一 partition 任一时刻可出现旧进程仍运行，但只有当前 epoch 能提交 transition；安全不依赖旧进程及时停止。非 owner 可接收外部 event，但不能执行其 transition。
- PostgreSQL 暂时不可用时停止 claim/commit，不能凭本地缓存延长 lease。
- partition ownership 不等于 Activity ownership；Activity at-least-once 语义保持任务 18 定义。
- 本任务不实现自动 reshard；固定配置比未验证的数据迁移更安全。

## 不做

- 不实现 Child、通用补偿、definition migration、归档、operator mutation或多 Region。
- 不使用内存选主/消息队列作为事实来源。
- 不用同进程两个线程冒充 HA 验收。

## 验证

- mapping golden：随机 WorkflowId 在 Windows/Linux/macOS 相同；非法 config/启动时不一致拒绝。
- 两进程争同 partition，只有一个 epoch 可 commit。
- pause 旧 owner 至 lease 过期，新 owner 接管；恢复旧 owner 后其 transition commit 全被 fencing 拒绝。
- 在 transition、Activity result、TimerFired、SignalReceived 并发点切换 owner：外部 event 依各自幂等键最多 append 一次且 sequence 连续，只有新 owner 消费并产生后续 command。
- 优雅 release 与 SIGKILL 两条路径；新 owner 仅从持久状态恢复。
- PostgreSQL 短暂重启、libpq 断连/重连后重新 claim，无 split-brain。
- 高并发多 partition 下每 task 归属正确，backpressure 不造成 starvation。
- shutdown 释放可安全释放的 lease；crash lease 由 TTL 回收。
- HA harness 复用任务 17/18 精确故障通道，在“外部 event 已持久化、后续 transition 未提交”窗口交接 owner。
- 至少两个完整 WorkflowSubsystem 进程复跑任务 18 六个 login 场景、多 scanner crash 和 outbox send-before-mark；结果与单节点 runtime golden、side_effect_marker 一致，纳入必跑 test-postgres。

运行 `zig build test-all` 与 `zig build test-postgres`。

## 验收清单

- [ ] 双 epoch schema、SQL predicate 和失败诊断完整。
- [ ] 至少两个真实进程完成 pause/kill/restart/DB restart 测试。
- [ ] 旧 owner 即使继续运行也不能提交。
- [ ] timer/activity/outbox 多进程边界不改变既有语义。
- [ ] 无 Child/迁移/归档占位代码。
- [ ] 全量验证通过。

