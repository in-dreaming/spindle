# 22 — Runtime 集成、Inspector、故障注入与发布门槛

## 前置

完成 00—21 全部任务；阅读架构第 3、42—50、53—55 节。传递依赖未全部绿色时不得开工。

## 目标

组装公开 Runtime，贯通四套独立上层模型的单向调用和 trace，完成全局 shutdown、inspector/replay bundle、故障注入、跨平台验证及发布门槛。

## 已决策公开接口

- 新增 `src/zruntime/runtime/root.zig`、`runtime.zig`，包根导出 `Runtime`/`RuntimeOptions`。
- Runtime 拥有 compute、blocking、main/render Pump、IoAdapter、Clock、Trace/Metrics。
- 可选 `WorkflowSubsystem` 拥有 libpq pool、scheduler、workflow/activity worker、timer scanner、outbox publisher；未以 `-Dpostgres=true` 配置时不构建该 backend，获取 WorkflowClient 返回 `WorkflowUnavailable`。
- WorkflowClient 直接复用任务 17，不另建入口或绕过 persistence。
- `deinit(policy, deadline)` 返回 shutdown report；初始化任一阶段失败按逆序释放已创建资源，半初始化 Runtime 不可见。

## 实现范围

- 固定单向接线：
  - ECS schedule → system/chunk jobs → compute；
  - Local Graph → target executor；
  - Resource Graph → executor/小 Local Graph；
  - Workflow Activity → 可选 Resource Graph → Local Graph/parallel I/O → executor。
- `tools/check_imports.zig` 固化允许 DAG并纳入 `test-all`：下层不得 import runtime/ECS/Resource/Workflow/Local Graph 上层语义；Workflow core 不 import ECS/Resource，只有应用 Activity 可组合它们。
- `observability/chrome_trace.zig`：复用 core TraceContext ID，有界采集、dropped count、有效 Chrome Trace JSON。
- `observability/replay.zig`：`ReplayBundle` envelope 仅索引任务 05 executor schedule、11 ECS journal、15 workflow history artifact；条目含 kind/path/content hash/trace ID，不解析或重复实现状态机。
- `observability/inspector_protocol.zig`：version/schema 的只读 snapshot/stream，投影既有 operator/read metrics；覆盖架构第 45 节以及 partition/child/compensation/archive/audit。CLI 不直接查询内部表或修改状态。
- Runtime 导出 NDJSON EventSink 和 metrics snapshot，禁用时保持零分配语义。
- `src/zruntime/testing/fault_injection.zig` 只在测试构建链接，复用既有 allocator/file/cache/DB/worker 故障点；Release 产物不得引用测试注入 symbol。

## Shutdown 固定顺序

1. 关闭新 workflow/graph/resource plan/ECS update/detached submit。
2. 停止 Workflow poll；短 Activity 收敛，长 Activity heartbeat 后释放/等待 lease。
3. Resource Graph 停止新 plan，running plan 收敛或协作取消。
4. ECS 停止新 frame，在当前 batch/command barrier 后收敛。
5. drain main/render Pump。
6. 取消/等待 IoAdapter pending completion，再 drain compute、blocking。
7. 收敛全部 DetachedHandle。
8. flush trace、metrics、NDJSON。
9. join 全部线程并释放内存/连接。

deadline 到期必须报告未收敛 task/lease/plan/I/O/detached；不得释放仍被线程访问的内存，`immediate` 也不能强杀线程。

## 固定集成产物

- `tests/integration/runtime_e2e.zig`：Activity 启动 Resource Plan → Local Graph → parallel file I/O → artifact，断言 workflow→activity→resource→local→executor 五级 span 和最终 hash。
- 同一 Runtime 并行运行 ECS update、Resource Plan、Workflow poll，断言 scheduler/state/handle 独立。
- `tests/integration/runtime_shutdown.zig`：三种 policy、每个 init/shutdown 阶段故障、Pump 未 drain deadline、I/O in-flight、DB lease 接管。
- `tests/integration/dependency_boundary.zig`、`runtime_fault_injection.zig`、`inspector_protocol.zig`、`replay_bundle.zig`。
- examples 固定为 `parallel_for.zig`、`local_graph.zig`、`ecs_update.zig`、`resource_build.zig`、`durable_login.zig`；最后一个复用 login fixture且仅在真实 DSN 下运行。
- `zig build run-examples`：每个示例断言结果/文件/DB/trace，禁止只打印 success。

## Benchmark 与发布检查

- `bench/schema.json` 固定输出字段：suite/samples/warmup/p50/p95/p99/throughput/zig/os/cpu/workers/seed/optimize。
- `bench/baselines/` 先提交明确机器环境的基线，再启用统计容差；没有稳定基线时只做 schema/smoke，不编造性能门槛。
- CI 增 `release-check`：三平台 test-all、Linux PostgreSQL/crash suite、可用 sanitizer、examples、benchmark schema、依赖许可证、公开 API docs。
- 文档产物：support matrix、known limitations、versioning、dependency licenses；README 仅引用实际可执行 API/命令。
- no-placeholder 检查扫描生产源码中的 TODO/FIXME、空实现、固定成功分支；测试 fixture 和文档中的说明性文字按明确 allowlist，而非全局忽略。

## 验证与最终验收

- Runtime 各 init 阶段注入失败后无线程、连接、句柄、内存泄漏。
- drain/cancel_pending/immediate 在 active ECS/graph/I/O/activity 下均按固定顺序收敛；新进程接管 durable 状态。
- Chrome Trace 可解析，五级 parent 链完整；ring 溢出时 dropped count > 0。
- ReplayBundle golden、hash/版本/缺项失败；各子系统 replay 仍由原任务执行。
- Inspector 与 operator/metrics 真值对比，协议畸形输入和版本协商安全。
- Windows/Linux/macOS 非 PG suite 全绿；Linux 真实 PG、双进程 HA、归档 HTTP、crash recovery 全绿。
- 五个独立示例和 benchmark schema 实际执行；durable login 无 DSN 时只能在非完整作业明确 skip，Linux 完整作业禁止 skip。
- [ ] 四套模型无万能节点或反向依赖。
- [ ] 仓库无未接线实现、必需测试 skip 或 README 超前声明。
- [ ] 所有发布检查通过。

