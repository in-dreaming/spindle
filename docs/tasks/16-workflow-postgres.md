# 16 — Workflow PostgreSQL 持久化与事务

## 前置

完成 15；阅读架构第 33、37、40、49.6 节。

## 目标

以 PostgreSQL 16+ 作为 Workflow 唯一事实存储，实现 schema、原子 history commit、乐观并发、lease、snapshot、inbox/outbox 和真实数据库集成测试。

## 实现范围

- `workflow/persistence.zig`：存储接口及事务输入/输出，语义以 PostgreSQL 实现为准，非“最小 mock 接口”。
- `workflow/postgres.zig`：唯一客户端选型为 PostgreSQL 官方 `libpq` 16+ C ABI，通过 `@cImport("libpq-fe.h")` 和 `linkSystemLibrary("pq")` 接入，不再选择第三方 Zig driver；连接池、参数绑定、binary-safe payload、deadline/cancel、错误映射。
- 构建选项 `-Dpostgres=true` 才编译 backend，并在缺少 libpq headers/library 时给出明确配置错误；核心库默认不要求系统安装 libpq。`test-postgres` 强制开启该选项。
- `db/migrations/` 创建版本化 SQL：
  - workflow_instance、workflow_history；
  - workflow_task、activity_task、durable_timer；
  - workflow_snapshot、inbox、outbox；
  - 主键、唯一键、状态/available_at/lease 索引和外键/检查约束。
- `workflow/persistence.zig` 公开唯一原子入口 `commitWorkflowTaskTransition`：锁定/验证 expected state_version 与 task lease_epoch，append history，更新 instance，按调用方给出的调度结果插入 activity/timer/outbox/下一 workflow task，完成当前 task；输入预留 `optional_snapshot`，非空时 snapshot 与其余写入同事务提交。`workflow_instance.owner_epoch` 在单节点阶段固定为 0；任务 19 才将其绑定为 partition owner epoch。
- history `(workflow_id, sequence)` 和 `event_id` 唯一；重复相同 event 幂等，冲突内容拒绝。
- task poll 使用 `FOR UPDATE SKIP LOCKED`、批量 claim、lease_owner/epoch/expire；过期后可重新 claim，旧 epoch 不能 commit。
- snapshot 写入 sequence/version/checksum；读取 latest snapshot + 连续 history。
- inbox message_id 去重与业务接收事务同边界；outbox claim/send 标记支持重复 publisher 而不丢消息。
- SQL migration runner 具备 advisory lock、版本表、事务化升级和 checksum，禁止运行被修改的已应用 migration。
- `test-postgres` 使用容器或用户提供 DSN 的真实 PostgreSQL 16+，每次建立隔离数据库/schema并清理。
- 更新 `.github/workflows/ci.yml`：Ubuntu 安装官方 libpq 开发包，使用锁定到不可变 digest 的 PostgreSQL 16 容器，注入 `SPINDLE_TEST_PG_DSN`，并确保 `test-all` 实际包含 `test-postgres`；Windows/macOS 未配置 libpq 时只运行非 PostgreSQL suite 并打印原因。

## 关键语义

- PostgreSQL server time 决定 lease/available_at；客户端墙钟不参与抢占正确性。
- timer 数据库列和 Zig 字段统一命名为 `fire_at_utc_ms`，存 UTC Unix 毫秒。
- Activity delivery 是 at-least-once；history commit 通过乐观并发 effectively-once。
- 任何 SQL 都参数化；payload 有配置上限；tenant/namespace 字段从首个 migration 纳入主键/索引隔离。
- 数据库暂时错误分类 retryable，约束/协议错误 non-retryable；事务失败整体回滚。
- 本任务不允许用进程内 map 或 SQLite 作为持久性验收替代。

## 不做

- 不执行 Activity、timer fire 或 outbox 网络发送。
- 不承诺 exactly-once 外部副作用。
- 不在单元测试里伪造 SQL 返回作为主要验收。

## 验证

- migration 从空库、重复执行、并发执行、已应用文件被修改。
- transaction 每个步骤故障注入/断连接，重连后要么全部存在要么全部不存在。
- expected state version 冲突、重复 event、sequence gap、旧 lease epoch。
- 多连接并发 poll，同一 task 同 epoch 只被一个 worker claim；lease 过期后新 epoch 可接管。
- inbox 重复、outbox publish-before-mark crash、snapshot + history读取。
- payload 二进制/上限、SQL 注入字符串、连接池耗尽和 shutdown。
- `zig build test-postgres` 必须运行真实 server，日志打印 server 版本但隐藏凭据。

运行 `zig build test-all` 与 `zig build test-postgres`。

## 验收清单

- [ ] schema、索引、约束与架构表模型一致并含 tenant。
- [ ] Workflow commit 是单一真实数据库事务。
- [ ] lease epoch 防止旧 worker 覆盖。
- [ ] crash/断连测试通过重连后查询验证。
- [ ] 全量验证通过。

