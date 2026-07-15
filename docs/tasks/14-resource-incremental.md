# 14 — Resource Fingerprint、缓存、Fusion 与高级规划

## 前置

完成 13、06；任务 06 提供 HTTP artifact 的流式 I/O、deadline/cancel 与 BlockingExecutor 隔离。阅读架构第 16、17.5—17.6、50.3、51 Phase 7 节。

## 目标

实现可验证的增量执行、本地内容寻址缓存、可插拔远程 artifact cache、受约束 task fusion 和动态成本/关键路径规划。

## 实现范围

- `resource_graph/cache.zig`：规范 fingerprint = task kind/version + canonical params + input version/hash + toolchain + relevant environment。
- canonical encoding 禁止 map 非稳定迭代、指针和进程随机 hash；同输入跨进程得到同 fingerprint。
- L0 进程内存和 L1 当前项目本地磁盘 CAS：临时写、checksum、fsync、原子发布、并发同 key 合并、LRU/配额 GC。
- L2 实现机器级共享目录 CAS（与 L1 同格式、独立配额和进程级锁）；L3 定义 `ArtifactStore` 并实现真实 HTTP(S) backend：HEAD/GET/PUT、流式校验、deadline、取消、重试和认证 header 注入；测试使用真实本地 HTTP server 进程和文件，不以函数 stub 验收。
- cache hit 校验 manifest、schema、size/hash 后注册 output version；损坏/缺项视为 miss 并隔离坏条目。
- `fusion.zig`：只合并声明同 kind、相邻 page/同 pack 且 fusion policy 证明等价的任务；保留每个原节点结果、trace 和失败归属。
- 编译期 critical path 与 downstream unlock；运行时 EWMA cost 更新只影响未来评分，不改变预算正确性。
- Phase 2 range：实现规范 byte/page interval 索引、split/coalesce 和 overlap；若无法在本任务完整实现，则不得宣称支持，保留 `UnsupportedRange`。本任务验收要求完整实现 byte_range。
- commit/recovery 将 cache artifact 与 current resource version 分离，缓存删除不破坏已提交 current。

## 关键语义

- cache 是优化，不是事实来源；任何命中都必须经 hash/schema 校验。
- HTTP backend 只存 artifact/blob，不存 Workflow history。
- task fusion 不可改变可见依赖、版本边界、取消和错误语义。
- fingerprint relevant environment 必须由 task 显式白名单，不能包含无关机器路径导致永不命中。
- range index 所有重叠结果须与朴素扫描等价。

## 不做

- 不实现云厂商专属 SDK 或分布式锁。
- 不以固定“cache hit=true”路径跳过真实恢复。
- 不将动态成本当硬预算替代声明上限。

## 验证

- fingerprint golden/cross-process、参数顺序、环境白名单、toolchain/version 变化。
- L1 并发写、进程重启命中、截断/bit flip、配额 GC、写中崩溃恢复。
- 本地真实 HTTP server 验证上传/下载、断流、错误码、重试、取消、checksum。
- hit 后 materialized outputs 与 cold execution 字节相同。
- fusion 前后随机可融合图的输出/version/hazard 等价，失败映射正确。
- interval index 随机区间与 O(n) reference 全量比较。
- benchmark 构图、hazard、cache、fusion、makespan、peak memory。

运行 `zig build test-all`。

## 验收清单

- [ ] fingerprint 完全规范化且有跨进程测试。
- [ ] L1/HTTP cache 均有真实 I/O 验证。
- [ ] 坏缓存不会成为成功结果。
- [ ] fusion 与 range index 通过 reference 等价测试。
- [ ] 全量验证通过。

