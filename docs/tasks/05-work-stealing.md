# 05 — Work-Stealing Compute Executor

## 前置

完成 04；阅读架构第 10、12、46.1、49.2、50.1 节。

## 目标

实现生产可用的 CPU 主执行器：本地优先队列、全局 injection、随机 steal、精确唤醒、help-while-wait 与确定性调试模式。

## 实现范围

- `executor/work_stealing.zig`：固定 worker、每 worker high/normal/background bounded deque、urgent/injection MPMC queue。
- worker 注册和 thread-local context：ID、scratch allocator、task cache、RNG、sleep state、stats。
- 获取顺序严格落实架构 10.2；critical 通过 urgent queue，background 不得饿死。
- worker 内 spawn 优先本地 deque，满时转 injection；外部 submit 进入 injection。
- 批量 submit 计算新增并行度，只唤醒必要 worker。
- 空闲策略：有界 spin → yield → semaphore/event park；关闭时可靠唤醒全部。
- Counter/Scope 在 worker 内等待时执行 `tryExecuteOne`，无任务时短 park；外部线程仍阻塞。
- priority aging：持续 high 流量下 normal/background 有明确最大连续跳过次数。
- `deterministic_executor.zig`：单线程、稳定 ready 序；record 记录 task ready/选择/steal 等决定，replay 校验任务身份和序列，不匹配立即报错。
- worker scratch 每任务或明确 epoch reset，任务不得持有逃逸 scratch 指针。

## 关键语义

- worker 不因等待自己派生的子任务占住线程造成池饥饿。
- 任务恰好进入一个终态；steal 与 owner 竞争不能重复执行。
- submit 唤醒不是广播风暴；sleeping_workers 计数与实际状态一致。
- deterministic 模式保证调度决定稳定，不承诺跨平台浮点自动确定。
- replay 日志有版本、checksum、任务稳定调试 ID；不持久化函数地址。

## 不做

- 不动态扩容本地 deque。
- 不实现 NUMA、P/E core 自动放置或任意实时优先级。
- 不以 FixedPool 代理 WorkStealingExecutor。

## 验证

- 单 worker、多 worker、worker 递归 spawn、外部集中提交、不均匀任务、高 fan-in/out。
- 本地队列溢出后 injection fallback 无丢失。
- 多 thief 竞争、worker sleep/wake、shutdown/submit/cancel 竞争。
- 构造 worker 数量等于父任务数量、每个父任务等待子任务的场景，证明 help-while-wait 无死锁。
- priority starvation 测试验证 aging 上限。
- record 后 replay 得到相同调度事件；篡改/截断日志明确失败。
- benchmark 空任务及 1/10/100 μs、1 ms 工作量，输出 throughput、p50/p95/p99、steal/idle、每任务内存。

运行 `zig build test-all` 和 `zig build bench -Doptimize=ReleaseFast`。

## 验收清单

- [ ] 实际使用 work-stealing deque，而非仅全局队列。
- [ ] help-while-wait、精准唤醒、优先级 aging 均有压力测试。
- [ ] record/replay 有真实校验，不是重复顺序执行的别名。
- [ ] 所有 worker shutdown 后 join，scratch/task cache 无泄漏。
- [ ] 全量验证通过。

