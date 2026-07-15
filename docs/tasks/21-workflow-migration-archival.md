# 21 — Workflow 迁移、归档、安全与 Operator

## 前置

完成 20、14；归档必须复用任务 14 的 `ArtifactStore` 与真实 HTTP backend。阅读架构第 39、40、45 Workflow、47.3、51 Phase 9 节。

## 目标

交付 definition 显式迁移、hot/cold history 归档、tenant 安全边界和经授权审计的 operator API。

## 协议与数据模型

- 新增稳定 event `DefinitionMigrated`，包含 from/to version、old/new state hash、migration schema version；operator terminate 复用任务 20 已定义的 `WorkflowTerminated`（principal/reason 必填）。
- 新增 migration lease 表：workflow_id 唯一、operator_id、from/to、lease_epoch/expiry；存在有效 lease 时 scheduler 不 claim 新 workflow task。
- 新增 `workflow_archive`：workflow_id、archive_id、sequence_from/through、event_count、manifest artifact ID/hash/schema、status。
- 新增 `workflow_audit_log`：audit_id、tenant/namespace、principal、action、target、idempotency_key、payload_hash、result、UTC time。
- 已应用 SQL migration 不可修改，继续遵守任务 16 checksum。

## 实现范围

- `workflow/migration.zig` 编排：等待已 claim task 完成或过期 → 获取 migration lease → 加载/校验完整 state → 调用任务 15 的纯 migrate → append DefinitionMigrated、更新 definition_version、写新 snapshot、释放 lease，单事务完成最终切换。
- migration 期间 signal 仍可按序 append history但不创建可运行 transition；迁移成功后统一 wake。旧 worker 的 task/partition epoch 或 migration predicate 不匹配时 commit 失败。
- fixture 增加 `game.login` v4 和唯一 3→4 migration；v3 golden 保持不变。
- `workflow/archival.zig`：仅 completed 且超过 tenant retention 的 workflow；生成 manifest（sequence range/count、逐块及整体 hash、schema）→ ArtifactStore PUT → 读回校验 → 事务记录 archive pointer → 才允许删除已归档 hot rows。
- history reader 组合 archive + hot tail，验证 sequence 连续；缺失/损坏 artifact 明确失败且不伪造空 history。
- `workflow/security.zig`：Principal + RBAC（viewer/operator/admin）、tenant/namespace 强隔离、activity/schema allowlist、payload/history/replay step/并发实例配额。
- audit/inspector 对 schema 标记 sensitive 的字段只记录 hash/脱敏值；首版不自行实现 at-rest encryption，部署文档要求 PostgreSQL/ArtifactStore 加密。
- `workflow/operator.zig`：
  - viewer：inspect/history/pending/child/compensation/archive/audit；
  - operator：cancel、retry failed Activity/compensation step；
  - admin：terminate、migrate、archive。
- mutation 全部要求 idempotency key、principal、reason，并在同事务写 audit；越权尝试也写安全审计（独立可靠事务）。

## 关键语义

- 迁移失败整体回滚，实例继续固定旧 version；已有 history 不运行新 logic。
- terminate 写专用 event并停止普通 transition，不等同 cancel。
- ArtifactStore 不是 history 事实的唯一索引；数据库 archive manifest pointer 是发现入口。
- archive 上传/校验失败禁止删除 hot history；删除后仍能完整 replay。
- operator 不直接修改 state payload、history 行或 lease epoch。

## 验证

- v3→v4 成功、migration function 失败、并发 signal、旧 worker commit、lease 过期接管；最终 history/replay确定。
- terminate/cancel 区别，所有 mutation duplicate idempotency key 返回同结果。
- 归档 upload 前后、校验后/DB pointer 前后、删除 hot 前后 kill；重启后至少一份完整 history可用。
- archive + hot tail replay 与归档前 canonical state/commands相同；损坏/缺失对象明确失败。
- RBAC 权限矩阵、跨 tenant/namespace、配额、allowlist、payload/replay上限。
- audit 对成功/失败/越权操作完整，敏感 payload 不以明文出现。
- retry compensation step 复用原 plan/ActivityKey 语义，不重复已完成 step。

运行 `zig build test-all` 与 `zig build test-postgres`。

## 验收清单

- [ ] 迁移有 lease/fencing、marker、snapshot 和原子版本切换。
- [ ] 归档 crash 任何阶段都不丢完整 history。
- [ ] hot/cold 组合可真实 replay。
- [ ] Operator mutation 全部授权、幂等、审计。
- [ ] tenant 隔离和敏感字段处理有负向测试。
- [ ] 全量验证通过。

