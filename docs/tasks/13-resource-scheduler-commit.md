# 13 — Resource 预算调度、执行与事务提交

## 前置

完成 12、05；必须使用任务 05 的 WorkStealingExecutor 以及任务 04 的 Blocking/Pump 路由真实任务。阅读架构第 17、18、44.4、49.4 节。

## 目标

把 dependency-ready 与 budget-runnable 分离，按多维预算调度真实资源任务，并以文件系统事务日志实现可恢复 Commit Group。

## 实现范围

- `resource_graph/budget.zig`：ResourceCost、ExecutionBudget、按 device/backend 的 limiter；原子 reserve-all/release-all。
- `scheduler.zig`：ready 集合、预算检查、执行路由、完成释放、age；本任务评分使用 downstream unlock（静态出度）、memory release、locality、age、resource pressure 的可解释分项。`critical_path_score` 在任务 14 接线前固定为零且测试断言未伪造。
- 防饥饿：任务随等待提升 age；单任务成本超过总预算在启动前返回 `UnschedulableCost`，不永久挂起。
- 节点错误和取消传播：停止新下游，已运行收敛并释放全部预算；临时版本标记 aborted。
- `plan.zig` execution handle 提供 ready/runnable/running/budget-blocked 状态快照。
- `resource_graph/commit.zig`：CommitGroup 与 CommitPolicy（至少 `atomic_replace`、`fail_on_conflict`）、prepare 临时版本、校验、build index、append+fsync commit record、原子 current pointer 切换、旧版本 GC。
- 生产文件 backend 使用同文件系统临时文件、fsync 文件与父目录、原子 rename/replace 的平台语义；不支持的原子能力明确失败。
- 启动 recovery 扫描 prepared 未提交、record 已存在但 pointer 未切换、临时/不可达版本；操作幂等。
- 接线 trace/metrics：ready、budget blocked、version、commit、release。

## 关键语义

- 多维预算必须全量预留成功才运行，失败不能留下部分 reservation。
- memory/disk/network/device 单位由调用方配置并记录，不用假精确测量代替声明成本。
- 排序评分可优化 makespan，但永远不能违反依赖、hazard、预算和 age 公平性。
- resource task 可重试的策略由调用方声明；commit pointer 切换有唯一事务边界。
- 文件 crash consistency 只能承诺已 fsync 的范围，文档需区分 OS/文件系统保证。

## 不做

- 不实现缓存/fingerprint、task fusion、远程 COS。
- 不用内存 map 冒充 crash recovery。
- 不承诺跨多个不支持原子 rename 的存储设备事务。

## 验证

- ready 但预算不足不执行；释放后运行；多维 reservation 无超额。
- 多设备 limiter、超预算任务、age 防饥饿、取消/失败后预算归零。
- 调度随机图与 reference verifier 比较依赖/hazard/预算不变量。
- 使用真实临时目录和子进程故障点：prepare 前后、record fsync 前后、pointer 切换前后、GC 前后；重启 recovery 后 current 只指向完整合法版本。
- 重复 recovery 幂等；损坏 record/checksum 安全失败，不删除最后有效版本。
- commit 并发竞争只有一个预期版本成功。

运行 `zig build test-all`。

## 验收清单

- [ ] Ready 与 Runnable 状态严格分离。
- [ ] 预算 reservation 原子且所有路径释放。
- [ ] crash 测试跨进程、跨重新打开验证。
- [ ] current version 永不指向未校验/未提交数据。
- [ ] 全量验证通过。

