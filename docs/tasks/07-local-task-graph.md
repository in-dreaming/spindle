# 07 — Local Task Graph

## 前置

完成 05；阅读架构第 14、41、42、49.3 节。

## 目标

实现低开销、一次性、进程内 DAG 的构建、编译、路由、执行、失败和取消传播。

## 实现范围

- `task_graph/node.zig`：NodeId、LocalTaskState、task payload、显式 target。
- `task_graph/builder.zig`：addTask、dependsOn、输入验证；builder 可失败但不能生成半有效 compiled graph。
- `task_graph/compiled_graph.zig`：冻结节点，验证 ID，去重边，Kahn/DFS 环检测，压缩 dependents，计算入度与 trace metadata。
- `task_graph/execution.zig`：每次 execution 拥有独立 dependency counters/state；同一 compiled graph 可串行或并发多次执行，除非 API 明确声明一次性并由测试约束。
- 公开类型名固定为 `LocalTaskGraph`（builder）与 `CompiledLocalTaskGraph`，由 `task_graph/root.zig` 和包根导出。
- target 路由：compute、blocking、main、render、serial ExecutorId；未知/未绑定 target 在启动前失败。
- failure policy 固定为：首个失败请求图取消；不再启动尚未提交节点；已运行节点协作收敛；依赖失败的节点为 cancelled；最终返回首错及可选完整诊断。
- GraphExecutionHandle 支持 wait、cancel、状态快照；handle 生命周期不依赖 builder arena。
- 追踪 NodeReady/Enqueued/Started/Finished/Cancelled 和依赖释放。

## 关键语义

- `dependsOn(b, a)` 表示 a 完成成功后 b 才可运行。
- empty graph 立即成功；孤立节点可并行。
- ready 转换必须只有一个线程获胜，fan-in 最后一个依赖只提交一次。
- main/render Pump 未被调用时 `GraphExecutionHandle.wait` 阻塞等待但不代替绑定线程 pump；调用方必须持续 drain 对应 Pump，否则可触发传入 deadline 并返回诊断。Runtime 集成任务仅包装该既定语义，不得偷偷改路由到 compute。
- Local graph 不持久化、不做资源 hazard、不包含 workflow timer。

## 不做

- 不添加 ResourceAccess、ECS component mask、重试或持久状态字段。
- 不允许运行期动态加边。
- 不通过每轮扫描所有节点寻找 ready。

## 验证

- 环（自环、多节点）、重复边、无效 ID、empty、孤立节点。
- 大 fan-in/fan-out、菱形 DAG、随机 DAG 与串行拓扑 reference 对比。
- 多 executor 路由验证实际执行线程，Pump target 由测试主动 drain。
- 节点失败、提交失败、执行前/中取消、多个并发 failure。
- 并发执行同一 compiled graph 不共享状态。
- fan-in 压力测试确认节点恰好执行一次；所有终态节点计数等于总节点数。
- trace 中每个 started 有唯一 finished/cancelled 配对。

运行 `zig build test-all`。

## 验收清单

- [ ] 编译产物不可变，执行状态独立。
- [ ] 环和非法 target 在任何节点运行前被拒绝。
- [ ] 失败/取消传播无悬挂节点或重复提交。
- [ ] 没有混入其他三套上层模型字段。
- [ ] 全量验证通过。

