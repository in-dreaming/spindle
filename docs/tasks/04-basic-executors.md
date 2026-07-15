# 04 — Task、Scope 与基础 Executor

## 前置

完成 03；阅读架构第 9、11、12、48、49.2 节。

## 目标

交付可实际用于工具任务的 Task ABI、Counter、结构化 Scope、Inline/Serial/Fixed/Blocking/Pump Executor 和完整 shutdown。

## 实现范围

- `executor/task.zig`：intrusive Task、状态机、优先级/flags、trace、run trampoline 和小 payload；拒绝重复提交。
- `executor/executor.zig`：类型擦除接口、SubmitOptions、SubmitError、workerCount/isWorkerThread/helpUntil。
- 在该文件定义稳定运行期 `ExecutorId`（slot + generation）及 target registry；ID 只在进程内有效。
- `executor/counter.zig`：计数完成同步；外部线程阻塞等待，worker hook 可帮助执行。
- `executor/scope.zig`：泛型 spawn、三种 ScopePolicy、错误收集、首错取消、等待所有已启动子任务。
- `executor/detached.zig`：显式 `submitDetached` 返回拥有生命周期的 DetachedHandle；payload 必须自拥有/堆拥有，API 不接受借用 Scope 栈数据，handle 可 wait/cancel 且 Runtime shutdown 必须收敛。
- `inline_executor.zig`、`serial_executor.zig`、`fixed_pool.zig`、`blocking_executor.zig`、`pump_executor.zig`。
- Safe TaskHandle 使用 slot+generation；ScopedTaskHandle 只在 Scope 生命周期内可用。
- task storage：inline payload + slab；`executor/frame_arena.zig` 实现三缓冲 rotate，每个 epoch 绑定未完成计数，reset/复用前强制完成，Debug 检测提前 reset。
- 所有 executor 实现 drain、cancel_pending、immediate 三种 shutdown policy；shutdown 开始后 submit 明确失败。
- BlockingExecutor 有独立线程和有界队列，达到上限返回 backpressure，不借用 compute worker。

## 关键语义

- Task 状态至少为 created → queued → running → completed/failed/cancelled；终态不可重入。
- run 函数 panic/不可恢复错误的策略必须一致：记录 failure、完成 counter、唤醒 waiter，不能遗留 running。
- Scope 捕获数据不得逃逸；API 设计使常规用法由词法作用域约束，文档指出 unsafe/raw 入口责任。
- PumpExecutor 只由绑定线程 drain，支持 max_tasks 与 monotonic time budget。
- SerialExecutor 保证接受顺序；FixedPool 不保证全局完成顺序。
- BlockingExecutor 运行阻塞任务，不允许其伪装成 compute executor 的 alias。

## 不做

- 不实现 work stealing、record/replay 或 I/O adapter。
- 不提供无 handle、无所有权的 fire-and-forget；detached 必须走上述显式 API。
- 不用 detached thread 实现每个 Task。

## 验证

- 每种 executor 的提交、执行线程、队列满、错误、取消、重复提交和三种 shutdown。
- Scope 三种策略，多子任务同时失败，首错后已启动任务收敛，未启动任务取消。
- worker 内 fork/join 在 FixedPool 饱和时不得死锁；必要时通过基础 helpUntil 执行全局队列任务。
- Pump 的任务数和时间预算边界；Serial 的严格 FIFO。
- task handle stale generation、payload 边界和 OOM 回滚。
- detached 在创建 Scope 返回后继续安全完成、捕获借用数据被 API/Debug 拒绝、handle 丢弃策略明确；shutdown 时收敛。
- Frame Arena 三轮 rotate、跨帧在途、提前 reset 检测和 OOM。
- shutdown/submit 竞争百万级随机操作，有 watchdog 且结果元素守恒。

运行 `zig build test-all`。

## 验收清单

- [ ] 结构化并发是默认且无逃逸悬垂捕获。
- [ ] Detached 仅经显式自拥有 API，Frame Arena 不会复用在途内存。
- [ ] 错误/取消后 counter、handle、内存均收敛。
- [ ] Blocking 与 Compute 线程域真实隔离。
- [ ] shutdown 后不接受任务且线程全部 join。
- [ ] 全量验证通过。

