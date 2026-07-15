# 03 — 并发队列、Work-Stealing Deque 与 Slab

## 前置

完成 02；阅读架构第 8、10.1、12、49.1 节。

## 目标

实现有界、无数据丢失且内存序可证明的 SPSC/MPSC/MPMC 队列、固定容量 Chase-Lev 风格 deque 和任务内存池。

## 实现范围

- `concurrent/spsc_queue.zig`：泛型有界 ring，tryPush/tryPop、批量操作、cache-line padding。
- `concurrent/mpsc_queue.zig`：多 producer、单 consumer；定义并测试关闭与剩余项 drain。
- `concurrent/mpmc_queue.zig`：每 slot sequence 的 bounded ring；full/empty 明确返回，不覆盖数据。
- `concurrent/work_stealing_deque.zig`：owner push/popBottom，thief stealTop；最后一个元素竞争正确。
- `concurrent/intrusive_list.zig`：只实现后续 task wait/list 所需操作，所有权和 ABA 前提写入文档。
- `concurrent/slab.zig`：固定 size class、对齐、批量领取、worker-local freelist、归还全局；Debug double-free/foreign-pointer 检测。
- 队列统一支持 `close`：关闭后拒绝新 push，已入队元素仍可 pop，耗尽后返回 closed。
- 暴露统计快照：push/pop/full/empty/contention；统计禁用时不改变语义。
- 容量规则固定：SPSC 支持任意正整数；MPSC/MPMC/deque 要求容量为不小于 2 的 2 次幂，非法配置在 init 返回错误。

## 关键语义

- 容量在初始化时固定；首版 deque 满由调用者转 injection queue，本类型不得偷偷扩容。
- 值的析构责任必须明确：成功 push 后归队列，失败仍归调用方；deinit 对残留元素按显式回调处理。
- MPSC/MPMC 不允许通过单一全局 mutex 冒充无锁 bounded queue；若某辅助路径加锁须说明且不覆盖核心入出队。
- deque 只能由注册 owner 调用 bottom 操作，Debug 检测违规。
- 所有 index wrap-around 使用定义良好的无符号回绕和容量约束。

## 不做

- 不实现动态 deque、epoch reclamation、hazard pointer。
- 不实现无界队列。
- 不靠超大固定容量规避 full 语义测试。

## 验证

- SPSC 容量 1/2/非 2 次幂；MPSC/MPMC/deque 验证容量 1 和非 2 次幂被拒绝，并覆盖 wrap-around、full/empty/close/drain。
- 多 producer/consumer 用唯一序号传递百万级元素，验证无重复、无丢失、每 producer 顺序约束。
- deque 覆盖 owner 与多个 thief 争最后元素、满后 fallback 由测试调用方接收。
- slab 覆盖 OOM、对齐、跨线程归还、double free、deinit 残留。
- 添加小状态空间 model test，将并发结果与串行 reference model 比较。
- sanitizer 可用平台运行 Address/Thread sanitizer；不可用时仍运行 Debug poison/canary 压力测试。

运行 `zig build test-all`。

## 验收清单

- [ ] full/empty/closed 三种结果不混淆。
- [ ] 生产/消费所有权和内存序有逐项说明。
- [ ] 压力测试能证明元素守恒。
- [ ] 无动态 deque 或伪无锁 mutex 队列。
- [ ] 全量验证通过。

