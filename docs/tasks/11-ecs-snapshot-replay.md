# 11 — ECS Snapshot、Rollback 与 Replay

## 前置

完成 10；阅读架构第 27、46.2、47.2、49.5 节。

## 目标

实现带 schema 的全量/增量 snapshot、可靠 restore、有限窗口 rollback 和可复现 ECS 输入重放。

## 实现范围

- `ecs/snapshot.zig`：World Header、Component Schema Table、Archetype Table、Chunk Columns、Entity Location、External Handle Reference。
- 格式复用 core envelope，固定字节序、版本、长度上限、checksum；按 archetype→chunk→column 序列化。
- restore 先完整解析/校验到临时 world，成功后原子替换；未知必需组件、迁移断链、损坏数据均不修改现 world。
- schema registry 执行逐版本 component migration；tag、非平凡组件和 external handle 有明确 codec 要求。
- incremental snapshot 记录 create/destroy/migration/changed column/external handle 变化，并引用准确 base snapshot ID/hash。
- `ecs/frame_journal.zig` 并接线 `world.update`：每帧由调用方提交 Input/Network Event、Random Seed 和 External Authoritative Data envelope，框架追加最终合并后的 Structural Commands；缺少必需输入时该帧标记为不可 replay，禁止伪造默认值。
- rollback ring 保存周期性全量/增量 snapshot、输入、命令、随机种子和外部 authoritative data；超出窗口明确失败。
- replay 从 snapshot 恢复后使用 DeterministicExecutor 重新执行；比较 world canonical hash 和逐 frame trace。
- stable iteration：archetype、chunk、entity/command 的确定顺序在 deterministic 模式固定。

## 关键语义

- Snapshot 是 ECS 状态载体，不复用 Workflow snapshot/history。
- incremental snapshot 只能应用于匹配 base；禁止“尽量应用”。
- restore 后 entity generation/location、archetype edge/query cache 均一致；缓存可重建但结果必须等价。
- external object 不被盲目序列化，必须由注册 resolver 将稳定 handle 解析或报告缺失。
- 浮点位级确定性只在相同声明的平台/策略内保证；跨平台限制写入格式 metadata。

## 不做

- 不实现编辑器反射、通用网络传输协议或无限 rollback 历史。
- 不把原始指针写入 snapshot。
- 不仅比较 entity 数量冒充状态一致。

## 验证

- 包含多个 archetype、空/满 chunk、tag、迁移历史、stale slot 的 golden round-trip。
- 数据截断、checksum、长度炸弹、未知 schema、迁移失败、错误 base；原 world 不变且无泄漏。
- full + 多个 incremental 与直接 full snapshot canonical hash 相同。
- rollback 到 N 后重放 N+1..M，逐 frame hash 与首次执行一致。
- journal 覆盖输入/网络/随机/structural/external 五类记录，截断或漏交必需输入时 replay 明确失败。
- external handle resolver 成功/缺失；非平凡组件 codec 生命周期计数。
- snapshot decoder fuzz 和 payload 上限测试。

运行 `zig build test-all`。

## 验收清单

- [ ] 持久格式稳定且有 golden bytes。
- [ ] restore 具备全有或全无语义。
- [ ] incremental 严格绑定 base。
- [ ] rollback/replay 比较完整 canonical state。
- [ ] 全量验证通过。

