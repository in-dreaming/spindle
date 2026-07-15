# 02 — 平台线程层与同步原语

## 前置

完成 01；阅读架构第 6、7、48、49.1 节。

## 目标

在 `std.Thread` 上提供真实三平台线程能力和可用于 executor 的同步原语，保证 deadline、取消、虚假唤醒和 shutdown 语义完整。

## 实现范围

- `platform/thread.zig`：ThreadConfig、命名、join、当前线程标识；栈大小按平台能力应用。
- `platform/affinity.zig`、`priority.zig`、`topology.zig`：逻辑 CPU 数和手工 affinity；Windows processor group、Linux affinity、macOS affinity 不可严格保证时返回能力错误而非假成功。
- `platform/windows.zig`、`linux.zig`、`macos.zig` 分别封装 WaitOnAddress、futex、ulock/标准条件变量回退；编译期只分析目标平台文件，公开上层只依赖统一 Park API。
- `sync/spin_mutex.zig`：pause、指数退避、Debug owner 棟测、可选 contention 计数。
- `sync/adaptive_mutex.zig`：短自旋 → yield → park；unlock 只在有 waiter 时唤醒。
- `sync/event.zig`：manual/auto reset、generation、防 lost wakeup、绝对 deadline；wait 接受 sync 层最小 `CancelWait` view（原子状态 + 注册/注销唤醒），不导入 executor。
- `sync/condition.zig`：与 AdaptiveMutex 配套，predicate loop、signal/broadcast、deadline/cancel，正确处理虚假唤醒。
- `sync/semaphore.zig`：计数上限、批量 release、deadline/cancel wait。
- `sync/latch.zig`、`barrier.zig`、`wait_group.zig`、`once.zig`。
- `executor/cancellation.zig`：唯一的 CancellationSource/Token 定义，实现/导出到 `CancelWait` view 的转换；一次性、线程安全、可轮询且能唤醒已注册 wait。该低层文件不得导入其他 executor 实现。

## 关键语义

- deadline 使用 monotonic clock；`timeout == now` 不得阻塞。
- 取消是协作式，取消 source 后所有当前/未来 wait 观察到 cancelled。
- Event auto-reset 每次 signal 最多释放一个 waiter；manual-reset 在 reset 前释放所有 waiter。
- Barrier 固定 participant 数；错误的 arrive 次数在 Debug 检测，Release 返回错误或保持定义行为。
- Once 的初始化失败不得发布半初始化值；明确选择并实现“失败可重试”。
- `immediate` 不等于杀线程，本任务不提供强杀 API。

## 不做

- 不实现 P/E core、NUMA、LLC 分组和实时调度。
- 不静默忽略 affinity/priority 失败。
- 不用周期 sleep 轮询代替 park/wake。

## 验证

- 每个原语做单线程状态机测试与多线程竞争测试。
- 覆盖 signal-before-wait、wait-before-signal、reset race、deadline race、cancel race、spurious wake。
- WaitGroup 并发 add/done/wait，禁止计数下溢；Barrier 多轮复用。
- Condition 覆盖 signal/broadcast、signal-before-predicate、虚假唤醒和 cancel/deadline 竞争。
- Once 并发初始化只成功一次，首轮失败后恰好一次重试成功。
- 线程名/affinity/priority 在支持平台读取回验证；不支持平台验证明确错误。
- 压力测试使用 watchdog deadline 防挂死并打印种子，不依赖 sleep 判断完成。

执行 `zig build test-all`；三平台 CI 必须编译各自专有代码，当前平台运行相应测试。

## 验收清单

- [ ] park/wake 有真实 OS 或标准库阻塞实现。
- [ ] 所有 wait 都处理 deadline、取消和虚假唤醒。
- [ ] 原子序和状态机不变量有注释。
- [ ] 无平台假成功和资源泄漏。
- [ ] 全量验证通过。

