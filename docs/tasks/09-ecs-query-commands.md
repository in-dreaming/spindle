# 09 — ECS Query、Deferred Commands 与事件

## 前置

完成 08；阅读架构第 21.2—22、24、25、26 节。

## 目标

交付类型安全/运行时校验的 chunk query、增量 QueryPlan、确定性 deferred structural commands、change detection 和 frame event。

## 实现范围

- `ecs/query.zig`：required/excluded/optional/changed mask，读写声明、QueryPlan、ColumnBinding、ChunkView。
- QueryPlan 记录 observed_archetype_version，只检查新增 archetype；registry/schema 变化使非法 plan 明确失效。
- ChunkView 对 read 返回 const slice、write 返回 mutable slice并更新对应 column version；Debug 追踪借用与声明一致。
- `ecs/command_buffer.zig`：每 worker buffer、全局单调 command sequence、create temp entity、destroy/add/remove/set。
- merge → stable sort（需要时）→ validate → apply；冲突规则固定为 Destroy 优先，同组件 add/remove/set 按 sequence，重复 destroy 幂等但 Debug 记录冲突。
- 批应用在验证阶段失败时不产生部分结构变更；apply 中资源失败需事务式回滚或预分配全部所需容量。
- `ecs/event.zig`：ImmediateEvent 仅调用栈；FrameEvent 使用 worker-local buffers，barrier 后稳定 merge，明确消费 phase 和双缓冲生命周期。
- change tick 使用 wrapping arithmetic；chunk/column 粒度 changed query，记录 system/read cursor 所需比较函数。
- 提供 partitioned inbox/event-buffer 模式，禁止 query job 随机写其他 chunk。

## 关键语义

- Query 声明中的 write 是权限和调度依据，不能通过 read API 获得 mutable 指针。
- 新增 archetype 后已有 QueryPlan 增量更新，不全量重扫旧 archetype。
- temp entity 只能在同一 command batch 后续命令引用，apply 后解析为真实 Entity。
- Release 结果仍稳定；Debug 额外报告冲突而非改变最终规则。
- tick 回绕比较仅在差值小于半范围的有效窗口内使用，并文档化。

## 不做

- 不实现 System batch 并行。
- FrameEvent 不承担保存、网络复制或跨帧持久化。
- 不添加 entity 级 dirty bit。

## 验证

- required/excluded/optional/changed 组合、空 query、多 archetype、tag。
- 新 archetype 后只增量匹配，已有 binding 不重建。
- 非声明写、重叠 mutable borrow、结构变更期间活跃 borrow 在 Debug 被拒绝。
- 每类 command 与 destroy+add、add+remove、多 set、双 destroy冲突；不同 merge 到达顺序在同 sequence 下结果相同。
- command 批 OOM/无效 schema/stale entity 时无部分应用。
- tick 在 `maxInt(u32)` 附近回绕；FrameEvent merge 顺序和生命周期。
- 随机 command 流与 reference model 比较。

运行 `zig build test-all`。

## 验收清单

- [ ] QueryPlan 真正增量更新。
- [ ] 声明访问与实际借用可校验。
- [ ] command merge 在 Release 也确定。
- [ ] 批失败不留下部分迁移。
- [ ] 全量验证通过。

