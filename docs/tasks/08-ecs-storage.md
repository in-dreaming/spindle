# 08 — ECS Entity、Registry、Archetype 与 Chunk

## 前置

完成 01；阅读架构第 19—21 节。

## 目标

建立不依赖并发 HashMap 的 ECS 主存储，实现 generational entity、稳定组件注册、32 KiB 起步的 SoA chunk 和正确 archetype 迁移。

## 实现范围

- `ecs/entity.zig`：Entity、EntitySlot、EntityLocation、free list；destroy 后 generation 增加并检测 stale handle。
- `ecs/component_registry.zig`：稳定 ComponentTypeId、name、size/alignment、init/deinit/move/clone、schema version/flags；冻结及一致性校验。
- `ecs/signature.zig`：组件集合 bitset、稳定排序、hash 后 exact compare。
- `ecs/chunk.zig`：布局计算、64 字节对齐 storage、entity column、SoA columns、count/capacity、column change versions。
- `ecs/archetype.zig`：signature、chunk 集合、add/remove edge cache。
- `ecs/world.zig`：create/destroy、get/has、add/remove/set、archetype lookup、archetype_version。
- 完整迁移顺序：目标分配、move 共有列、init 新列、deinit 删除列、源 swap-remove、更新两个 location；任一步失败必须回滚或保持原 entity 可用。
- 外部大型对象仅存调用方定义的稳定 handle，不把对象所有权隐含塞进 ECS。

## 关键语义

- ComponentTypeId 来自显式 stable name/manifest 映射，不按注册顺序分配。
- 组件主数据只存在 chunk column；HashMap 仅允许 signature→archetype 的低频查找。
- `getMut` 更新 column change version；返回借用的生命周期不得跨结构变更。
- 非平凡组件的 move/deinit 恰好一次；swap-remove 后被移动 entity location 必须立刻更新。
- 零尺寸组件作为 tag，不分配数据列但参与 signature。
- World 单线程结构变更；并行 deferred commands 在任务 09 实现。

## 不做

- 不实现 Query、System Scheduler、Snapshot。
- 不给每个 component/entity 加 mutex。
- 不用 `Entity -> HashMap<Component>` 作为 fallback。

## 验证

- create/destroy/reuse/stale generation；百万 entity slot 扩容与 OOM 回滚。
- 多 size/alignment、tag、非平凡生命周期组件的 chunk layout，不重叠且对齐。
- 所有 add/remove 组合和 edge cache 命中；迁移后值保持。
- 源 chunk 中间/末尾 swap-remove，双方 location 正确。
- init/move 分配失败故障注入，验证原状态和析构次数。
- 随机结构操作与简单 reference model 对比 entity→组件值（reference 仅用于测试，不进入生产）。
- Debug allocator 下 world deinit 无泄漏。

运行 `zig build test-all`。

## 验收清单

- [ ] 主存储确为 Archetype + Chunk + SoA。
- [ ] stable component ID 不受注册顺序影响。
- [ ] 迁移和失败回滚无双重析构/泄漏。
- [ ] stale Entity 永不访问复用 slot 的新对象。
- [ ] 全量验证通过。

