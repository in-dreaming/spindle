# 10 — ECS System Scheduler 与两级并行

## 前置

完成 05、09；阅读架构第 23—25、42、44.3 节。

## 目标

依据 component/singleton 访问、phase、before/after 和 target 编译 ECS schedule，并实现 system-level + chunk-range 两级并行。

## 实现范围

- `ecs/system.zig`：SystemId、SystemDesc、component/resource read/write mask、phase、target、run_fn。
- ECS singleton resource registry 与 borrow 校验；它与 Resource Graph 的 ResourceKey 完全不同。
- `ecs/schedule.zig`：验证 ID/phase/target，合并显式依赖和访问冲突，检测环，生成 CompiledPhase/SystemBatch。
- 在 `ecs/world.zig` 暴露并完整接线 `registerSystem`、`compileSchedule`、`update(runtime, dt)`，调用语义与架构第 53 节示例一致。
- batch 内系统保证无 component/singleton 写冲突；稳定 tie-break 使用 Phase 顺序、显式拓扑和 SystemId。
- 执行 batch：互不冲突 system 并行；每个 system 根据匹配 chunk 和 grain 切为 chunk ranges，而非一 chunk 一 task。
- 每 worker command/event buffer，在 batch barrier 后 merge/apply；结构变化发生后再进入后续 batch。
- system last_run_tick 只在成功完成并提交 command 后推进；失败请求本帧取消并保持可诊断状态。
- schedule dirty 仅由 system/access/phase/dependency 变化触发；本轮不实现插件加载器，只提供公开 `invalidateSchedule` 供未来插件集成。新增 archetype 只更新 QueryPlan。
- 接线 trace/metrics：SystemStart/End、ChunkJob、CommandMerge、ScheduleStall、AccessConflict。

## 关键语义

- A/B 可并行仅当双方 component 和 singleton 的 write-read/write-write 均无交集，显式边、phase、target 也允许。
- main/render target 必须路由 PumpExecutor，不得为提高并行度改投 compute。
- 一个可写 chunk/column 同时只交给一个 job；随机跨 chunk 写必须走事件或 partitioned inbox。
- system 声明与 query 实际访问不一致在启动前或 Debug 借用时失败。
- schedule compile 产物不可变，可在 world 配置版本未变时复用。

## 不做

- 不用 Local Task Graph 节点结构代替 ECS schedule。
- 不在每帧重新全量编译 schedule。
- 不给组件实例加锁解决冲突。

## 验证

- 各类 read/write/singleton 冲突矩阵与显式 before/after。
- 显式依赖环、未知 SystemId、跨 phase 非法边、非法 target。
- 无冲突 system 实际并行，有冲突 system 从不重叠；通过 barrier/原子探针验证而非 sleep。
- 大 query 切 chunk range，小 query 单 task；每行恰好处理一次。
- command barrier 后才发生迁移，后续 batch 可见；失败 system 的 tick 不推进。
- 新 archetype 不触发 schedule 重编但 query 能看到。
- deterministic executor 下 system/chunk/command 顺序可复现。

运行 `zig build test-all`，并添加 ECS 并行吞吐 benchmark。

## 验收清单

- [ ] 编译冲突图与运行时访问一致。
- [ ] 两级并行均真实发生且无任务爆炸。
- [ ] 结构变化只在 barrier 应用。
- [ ] 新 archetype 不导致全 schedule 重编。
- [ ] 全量验证通过。

