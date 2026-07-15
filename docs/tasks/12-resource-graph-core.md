# 12 — Resource Graph 模型、Hazard 与版本

## 前置

完成 01、07；阅读架构第 15、16、41、42 节。

## 目标

实现独立于 Local Graph 的资源身份、访问、版本和自动 RAW/WAR/WAW 依赖编译器。

## 实现范围

- `resource_graph/resource_key.zig`：file/page/memory_buffer/database_segment/gpu_buffer/texture/network_blob/custom 的结构 key，稳定编码、精确等价和缓存 hash。
- `resource_range.zig`：whole/page range 的重叠与规范化；类型可保留 byte/texture/custom，但 MVP 对未实现索引的范围在 compile 返回 `UnsupportedRange`。
- `access.zig`：read/write/create/delete、VersionConstraint、ResourceAccess 校验。
- `version.zig`：ResourceVersion、generation、可选 content hash、状态机；每次排他产出定义新版本。
- `manifest.zig`：注册到 core Schema Registry 的 Resource Manifest，稳定记录 key、version、content hash、artifact location 和 producer fingerprint。
- `dependency_builder.zig`：按资源/page frontier 维护 last_writer/active_readers，生成 RAW/WAR/WAW；显式边与自动边合并去重。
- `plan.zig`：Resource Task 描述、不可变 compiled plan、环检测、dependents/indegree、输入输出版本绑定。
- 节点 run_fn 可直接投 Executor 或构造小型 Local Graph，但 Resource Node 类型不得复用 LocalTaskNode。
- 诊断输出每条自动边的资源、访问模式和 hazard 原因。

## 关键语义

- hash 只加速查找，不是逻辑 resource identity；碰撞必须 exact compare。
- file/page 共享规范 `FileIdentity`。分层 frontier 规则固定为：page 访问检查同 file 的 whole writer/reader barrier 与该 page frontier；whole read 依赖 whole writer 和所有 page writers，并成为未来任意 page write 的 reader barrier；whole write 依赖并清空 whole 与全部 page frontier。不同 file identity 永不冲突。
- read 依赖 last writer；write/create/delete 依赖 last writer 和所有 active readers，然后清空 readers。
- create 要求目标不存在/版本约束匹配；delete 生成 tombstone 版本；非法生命周期在 compile 拒绝。
- compiled plan 可重复执行时，每次执行状态独立。

## 不做

- 不实现预算调度、缓存、commit 或任意 byte interval tree。
- 不把文件路径 hash 单独作为 key 且丢弃规范路径/namespace。
- 不借用 ECS Resource 类型。

## 验证

- key 编解码/hash 碰撞 exact compare、路径规范化的跨平台规则。
- RAW/WAR/WAW、read-read 无边、create/delete、显式边、重复访问合并。
- page 独立与 whole-parent 冲突规则。
- Resource Manifest golden bytes、未知 schema/version 和 artifact hash 校验。
- 非法 range、非法版本约束、生命周期错误、自动+显式边形成环。
- 随机访问序列与串行 hazard reference model 比较；执行时断言冲突节点从不重叠。
- compiled plan 并发执行不共享 node state。

运行 `zig build test-all`。

## 验收清单

- [ ] ResourceKey 是结构身份且处理 hash 碰撞。
- [ ] 三类 hazard 自动边完整且可诊断。
- [ ] 未支持 range 明确报错，不静默降级。
- [ ] Resource 与 Local/ECS 节点类型无复用。
- [ ] 全量验证通过。

