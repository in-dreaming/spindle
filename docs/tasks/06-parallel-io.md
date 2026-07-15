# 06 — 并行算法与 std.Io Adapter

## 前置

完成 05；阅读架构第 2.2、13、43、49、50 节。

## 目标

在 Executor 上交付有界粒度的并行算法，并通过适配层接入 Zig 0.16 `std.Io`，保证 compute worker 不被同步 I/O 长期阻塞。

## 实现范围

- `parallel/parallel_for.zig`：forRange/forEach/invoke，静态与动态分块，显式 grain 和 auto grain。
- `parallel/reduce.zig`、`scan.zig`、`sort.zig`、`pipeline.zig`：明确结合律、稳定性、临时内存和取消语义。
- auto grain 初始按 `worker_count × 4..8` 任务估算，并可使用调用点历史 ns/item；采样线程安全且不改变结果。
- 所有算法使用 Scope，首错取消并等待，空输入/单 worker/OOM 正确。
- `io_adapter/io_runtime.zig`：仅封装 Zig 0.16 `std.Io` 的 async/concurrent、Future/Group 能力；业务 API 不暴露具体标准库 backend 类型。
- `io_adapter/completion.zig`：completion 保存结果、trace 和 continuation executor，完成后投递回指定 executor。
- `io_adapter/blocking_bridge.zig`：无法异步化的操作明确提交 BlockingExecutor，支持 backpressure、deadline 和取消。
- 提供真实文件读写/定时器示例，证明 compute task 发起 I/O 后可继续执行其他任务。

## 关键语义

- reduce 默认只接受调用方声明可重排的结合操作；需要稳定顺序时走 deterministic 选项。
- scan 明确 inclusive/exclusive；sort 明确是否稳定，不能名称与行为不符。
- pipeline 每 stage 有有界容量，背压向上游传播，取消时 drain/释放所有 item。
- `std.Io` 不支持并发的 backend 可能同步完成，adapter 仍需返回一致 completion 语义。
- blocking bridge 不得在 compute worker 上直接调用阻塞函数。

## 不做

- 不复制实现一个新的 OS I/O backend。
- 不用 sleep 模拟文件/网络 completion 验收。
- 不实现 GPU 算法。

## 验证

- 算法与串行 reference 对比：空、小、大、非整除 grain、错误、取消、OOM。
- reduce/scan 使用整数 golden；浮点测试显式容差和 deterministic 模式。
- sort 覆盖重复 key、已排序、逆序和稳定性声明。
- pipeline 在慢 consumer、满队列、中途失败下无丢失/重复/泄漏。
- 使用真实临时文件完成异步写读校验；completion 确实在指定 executor。
- 构造慢阻塞操作占满 BlockingExecutor，同时 compute 任务仍前进；队列满返回 backpressure。

运行 `zig build test-all`；benchmark 记录 grain 与串行/并行拐点。

## 验收清单

- [ ] 并行算法不产生一元素一任务。
- [ ] 所有错误和取消经 Scope 收敛。
- [ ] `std.Io` 被隔离在 adapter 内。
- [ ] 真实 I/O 与 blocking 隔离测试通过。
- [ ] 全量验证通过。

