# 15 — Workflow 协议、确定性状态机与 Replay

## 前置

完成 01；阅读架构第 28—32、36、39、40、46.3 节。

## 目标

实现不依赖数据库的稳定 Workflow 协议、definition registry、显式 transition、command/event 转换和确定性 replay verifier。

## 实现范围

- `workflow/definition.zig`：WorkflowDefinitionId、stable name、version、state/event/command schema、TransitionFn；registry 冻结和版本并存。
- `workflow/instance.zig`：Stable WorkflowId、status、sequence/state version/owner epoch、时间字段及合法状态迁移。
- `workflow/event.zig`：架构列出的 event envelope 和 event kinds，稳定数值 ID，不持久化 enum ordinal。
- `workflow/command.zig`：schedule activity/timer/signal/child/complete/fail；command sequence 稳定且 replay 可比。
- `workflow/activity.zig`：ActivityKey、payload/result envelope、timeout/retry/failure 分类；仅定义协议，不执行副作用。
- `workflow/retry.zig`：指数 backoff、上限、max attempts、non-retryable；使用确定性 jitter seed 并把决定记录为 event/command metadata。
- `workflow/snapshot.zig`：state + event sequence + definition version + checksum；history 仍为事实来源。
- `workflow/migration.zig`：实例固定 definition version；显式逐版本 state migration，禁止静默换逻辑。
- Replay engine：snapshot + 后续 history → transition → commands，与历史已记录 command events逐项比对；不一致报告 sequence 和字段。
- WorkflowContext 只暴露 logical time、已记录 deterministic random、trace、command allocator；类型层面不提供网络/DB/file/system clock。
- `tests/fixtures/login_workflow.zig` 固定实现 `game.login` definition version 3、状态/event/command golden；任务 17、18 和 22 必须复用，不得另写 transition。

## 关键语义

- transition 处理一个输入 event，输出 new_state、commands、status；失败不发布半状态。
- sequence 从固定起点连续递增，不允许缺口、重复或乱序。
- command 与其对应 history event 的映射是规范协议，不能由 worker 临时猜测。
- ActivityKey = workflow_id + command_sequence；重复 Activity 必须可返回原 completed result。
- snapshot 只优化 replay，不能覆盖或删除尚未安全归档的 history。

## 不做

- 不实现数据库、worker、真实 Activity、timer scanner 或网络 API。
- 不执行 transition 内的真实副作用。
- 不持久化 Zig stack/fiber/函数地址。

## 验证

- definition 重名/重复版本/未知版本、实例状态机非法转换。
- event/command/snapshot golden bytes、schema migration、畸形 payload。
- 以登录流程纯状态机 fixture 覆盖正常、重连、超时和补偿 command 序列，但 fixture 不调用外部服务。
- 相同 history 多次 replay 状态/commands 字节相同。
- 篡改 event、漏 event、改变 definition logic/version 时 verifier 在准确 sequence 失败。
- retry 边界、溢出、jitter 可复现、non-retryable。
- transition 尝试读取未提供能力在编译/API 层不可行。

运行 `zig build test-all`。

## 验收清单

- [ ] 持久协议字段和 kind ID 稳定。
- [ ] Workflow logic API 无副作用能力。
- [ ] replay 真正比较历史命令，不只是重新跑出状态。
- [ ] definition version 固定且迁移显式。
- [ ] 全量验证通过。

