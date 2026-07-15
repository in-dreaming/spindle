# Zig 并发执行、ECS 与多层任务编排框架

## 完整架构设计文档

**文档状态**：架构设计稿
**目标语言**：Zig
**目标平台**：Windows、Linux、macOS；后续扩展 iOS、Android 和主机平台
**主要使用场景**：

* 游戏引擎运行时；
* ECS 系统调度；
* 物理、动画、粒子和渲染准备；
* 资源 Build、Merge、压缩和增量更新；
* 自动 Profiler Agent；
* 机器农场终端执行；
* 客户端、登录网关及多个游戏服务器之间的长生命周期异步流程；
* 通用 CLI 和后台工具。

---

# 1. 背景与目标

项目需要一套基于 Zig 的并发和执行基础设施。它不能只提供一个简单线程池，而需要覆盖不同性质的执行模型：

1. 内核线程、同步原语和并发容器；
2. Worker Pool 和 Work-Stealing Job System；
3. 进程内普通 Task Graph；
4. Resource-Based Task Graph；
5. Archetype + Chunk ECS；
6. 跨进程、可持久化、可恢复的 Durable Workflow；
7. 统一的追踪、诊断、取消、序列化和测试基础设施。

这些系统都包含“任务”和“调度”，但它们解决的问题不同：

* Job System 关心纳秒至毫秒级调度开销；
* ECS 关心组件访问冲突和数据局部性；
* 普通 Task Graph 关心进程内 DAG 完成依赖；
* Resource Graph 关心资源版本、访问冲突和多维预算；
* Durable Workflow 关心进程崩溃、消息重试、持久定时器和跨服务状态流转。

因此，本方案不设计一个包含大量可选字段的“万能图节点”，而采用：

> 底层公共设施共享，上层执行模型独立。

---

# 2. 设计原则

## 2.1 独立语义，有限复用

以下四类系统必须独立：

* ECS System Scheduler；
* Local Task Graph；
* Resource Task Graph；
* Durable Workflow。

它们可以共享：

* Executor；
* 线程和同步设施；
* ID 类型工具；
* Codec 和 Schema Registry；
* Clock；
* Trace Context；
* 错误编码规范；
* 部分取消接口。

它们不能共享：

* Node 数据结构；
* Scheduler；
* State 枚举；
* 生命周期；
* 依赖算法；
* 持久化模型。

## 2.2 CPU、阻塞和异步 I/O 分离

CPU 密集任务、阻塞调用和异步 I/O 必须进入不同执行域：

```text
Compute Executor
    └── 物理、解压、解析、ECS Chunk、图算法

Blocking Executor
    └── 第三方阻塞 API、同步文件接口、子进程等待

std.Io / I/O Backend
    └── 文件、网络、定时器等异步操作
```

Zig 0.16 将 `io.async`、`io.concurrent`、Future 和 Group 等并发能力纳入新的 `std.Io` 体系；其中 `async` 可由不支持并发的实现直接同步执行，而 `concurrent` 明确要求并发执行。自研框架应通过适配层使用这些能力，而不是把业务 API 与某一版 `std.Io` 紧耦合。

## 2.3 结构化并发优先

默认情况下：

* 创建者必须等待子任务；
* 捕获栈变量的任务不能逃逸作用域；
* Scope 返回前所有子任务必须结束；
* 失败时先发出取消，再等待已启动任务退出；
* Detached Task 必须显式使用独立 API。

## 2.4 ECS 不依赖并发哈希表

ECS 不采用 DashMap 风格架构，也不采用：

```text
Entity -> ConcurrentHashMap<Component>
```

ECS 主存储采用：

```text
Entity
  → Entity Location
  → Archetype
  → Chunk
  → SoA Component Columns
```

并发安全由 System Access Scheduler 和 Chunk 所有权保证，而不是通过给每个组件访问加锁实现。

## 2.5 持久流程不是 DAG

跨进程登录流程允许：

* 循环；
* 重试；
* 等待消息；
* 等待定时器；
* 断线重连；
* 补偿；
* 服务迁移；
* 运行数小时或数天。

它应建模为持久化事件驱动状态机，而不是普通 Task Graph。

---

# 3. 总体架构

```text
┌────────────────────────────────────────────────────────────┐
│                      Application Layer                     │
│ Game / Editor / Build Tool / Agent / Machine Farm Client   │
└────────────────────────────────────────────────────────────┘
              │                  │                  │
              ▼                  ▼                  ▼
┌──────────────────┐  ┌──────────────────┐  ┌─────────────────┐
│       ECS        │  │ Resource Graph   │  │ Durable Workflow│
│ World / Systems  │  │ Resource Version │  │ State / History │
│ Query / Schedule │  │ Hazard / Budgets │  │ Activity / Timer│
└──────────────────┘  └──────────────────┘  └─────────────────┘
              │                  │                  │
              └──────────┬───────┴──────────┬───────┘
                         ▼                  ▼
               ┌────────────────┐  ┌───────────────────┐
               │Local Task Graph│  │ Persistent Stores │
               │In-process DAG  │  │DB / Log / Outbox  │
               └────────────────┘  └───────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────┐
│                    Executor Runtime                        │
│ WorkStealing / FixedPool / Serial / Blocking / Pump        │
└────────────────────────────────────────────────────────────┘
                         │
                         ▼
┌────────────────────────────────────────────────────────────┐
│ Thread / Atomic / Futex / Queue / Allocator / Platform     │
└────────────────────────────────────────────────────────────┘
```

---

# 4. 模块和仓库结构

```text
zruntime/
├── core/
│   ├── id.zig
│   ├── stable_id.zig
│   ├── clock.zig
│   ├── error_code.zig
│   ├── hash.zig
│   ├── registry.zig
│   └── schema.zig
│
├── platform/
│   ├── thread.zig
│   ├── affinity.zig
│   ├── priority.zig
│   ├── topology.zig
│   ├── windows.zig
│   ├── linux.zig
│   └── macos.zig
│
├── sync/
│   ├── spin_mutex.zig
│   ├── adaptive_mutex.zig
│   ├── event.zig
│   ├── semaphore.zig
│   ├── latch.zig
│   ├── barrier.zig
│   ├── wait_group.zig
│   └── once.zig
│
├── concurrent/
│   ├── spsc_queue.zig
│   ├── mpsc_queue.zig
│   ├── mpmc_queue.zig
│   ├── work_stealing_deque.zig
│   ├── intrusive_list.zig
│   ├── slab.zig
│   └── epoch.zig
│
├── executor/
│   ├── executor.zig
│   ├── task.zig
│   ├── scope.zig
│   ├── counter.zig
│   ├── cancellation.zig
│   ├── inline_executor.zig
│   ├── serial_executor.zig
│   ├── fixed_pool.zig
│   ├── work_stealing.zig
│   ├── blocking_executor.zig
│   ├── pump_executor.zig
│   └── deterministic_executor.zig
│
├── parallel/
│   ├── parallel_for.zig
│   ├── reduce.zig
│   ├── scan.zig
│   ├── sort.zig
│   └── pipeline.zig
│
├── task_graph/
│   ├── builder.zig
│   ├── node.zig
│   ├── compiled_graph.zig
│   └── execution.zig
│
├── resource_graph/
│   ├── resource_key.zig
│   ├── resource_range.zig
│   ├── access.zig
│   ├── version.zig
│   ├── dependency_builder.zig
│   ├── budget.zig
│   ├── scheduler.zig
│   ├── cache.zig
│   └── plan.zig
│
├── ecs/
│   ├── entity.zig
│   ├── component_registry.zig
│   ├── signature.zig
│   ├── archetype.zig
│   ├── chunk.zig
│   ├── world.zig
│   ├── query.zig
│   ├── command_buffer.zig
│   ├── system.zig
│   ├── schedule.zig
│   ├── event.zig
│   └── snapshot.zig
│
├── workflow/
│   ├── definition.zig
│   ├── instance.zig
│   ├── event.zig
│   ├── command.zig
│   ├── activity.zig
│   ├── timer.zig
│   ├── retry.zig
│   ├── persistence.zig
│   ├── scheduler.zig
│   ├── worker.zig
│   ├── outbox.zig
│   ├── snapshot.zig
│   └── migration.zig
│
├── io_adapter/
│   ├── io_runtime.zig
│   ├── completion.zig
│   └── blocking_bridge.zig
│
└── observability/
    ├── trace.zig
    ├── metrics.zig
    ├── chrome_trace.zig
    ├── replay.zig
    └── inspector_protocol.zig
```

---

# 5. 公共核心类型

## 5.1 进程内 Generational ID

```zig
pub fn GenerationalId(comptime Tag: type) type {
    return packed struct(u64) {
        index: u32,
        generation: u32,

        pub const tag = Tag;
    };
}
```

适用于：

* Entity；
* Local Task；
* Graph Node；
* Executor；
* Resource Version Slot。

## 5.2 全局稳定 ID

跨进程对象使用：

```zig
pub const StableId = struct {
    high: u64,
    low: u64,
};
```

适用于：

* Workflow ID；
* Activity ID；
* Message ID；
* Trace ID；
* Resource Artifact ID。

生成方式可以是：

* UUIDv7；
* 时间有序 128 位 ID；
* 服务器分区 ID + 时间 + 序号。

跨进程数据不能使用：

* 指针；
* 进程内 slot；
* 编译期函数地址；
* 不稳定枚举序号。

## 5.3 Clock

```zig
pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        monotonicNow: *const fn (*anyopaque) u64,
        utcNow: *const fn (*anyopaque) i64,
    };
};
```

用途：

* Executor 和 Profiler 使用 monotonic clock；
* Workflow timer 使用 UTC 时间；
* 测试使用 VirtualClock；
* Replay 使用记录时钟。

## 5.4 Schema Registry

```zig
pub const SchemaMeta = struct {
    id: u64,
    version: u32,
    stable_name: []const u8,
    encode_fn: EncodeFn,
    decode_fn: DecodeFn,
    migrate_fn: ?MigrateFn,
};
```

用于：

* ECS Snapshot；
* Resource Manifest；
* Workflow Event；
* Activity Payload；
* Trace Event；
* 网络协议。

---

# 6. 线程和平台层

Zig 的 `std.Thread` 表示内核线程，并提供线程相关同步原语；平台层在其上补充线程名、优先级、Affinity 和 CPU 拓扑。

## 6.1 ThreadConfig

```zig
pub const ThreadConfig = struct {
    name: []const u8,
    stack_size: usize = 512 * 1024,
    priority: ThreadPriority = .normal,
    affinity: Affinity = .none,
    qos: QosClass = .default,
};
```

## 6.2 平台能力

### Windows

* `SetThreadDescription`；
* `SetThreadPriority`；
* CPU Sets 或 Processor Groups；
* WaitOnAddress；
* I/O Completion Port 适配。

### Linux

* `pthread_setname_np`；
* `pthread_setaffinity_np`；
* `sched_setscheduler`；
* futex；
* io_uring 适配。

### macOS

* `pthread_setname_np`；
* QoS；
* Mach thread policy；
* kqueue 等待适配。

## 6.3 CPU 拓扑

抽象：

```zig
pub const CpuTopology = struct {
    logical_cpu_count: u16,
    physical_core_count: u16,
    groups: []CpuGroup,
};

pub const CpuGroup = struct {
    numa_node: ?u16,
    cache_group: ?u16,
    performance_class: u8,
    logical_cpus: []u16,
};
```

Phase 1 只保证逻辑 CPU 数量和手工 Affinity。

Phase 2 再支持：

* P-Core / E-Core；
* NUMA；
* LLC Group；
* 线程迁移策略。

---

# 7. 同步设施

提供：

* SpinMutex；
* AdaptiveMutex；
* Semaphore；
* Event；
* Condition；
* Latch；
* Barrier；
* WaitGroup；
* Once；
* CancellationSource。

## 7.1 SpinMutex

仅适用于极短临界区：

```zig
pub const SpinMutex = struct {
    state: std.atomic.Value(u32),

    pub fn lock(self: *SpinMutex) void;
    pub fn unlock(self: *SpinMutex) void;
};
```

必须包含：

* CPU pause；
* 指数退避；
* Debug owner 检测；
* 可选 contention 统计。

## 7.2 AdaptiveMutex

策略：

```text
短时自旋
  → yield
  → futex/semaphore park
```

不能让所有锁永久 busy-spin。

## 7.3 Event

支持：

* Auto Reset；
* Manual Reset；
* 带 generation 的等待；
* Deadline；
* Cancellation。

---

# 8. 并发容器

## 8.1 SPSC Queue

用途：

* 音频线程命令；
* Render Thread 提交；
* 单 producer 日志通道；
* 固定线程之间通信。

## 8.2 MPSC Queue

用途：

* 多 Worker 提交到 Serial Executor；
* 多线程提交到 Main/Render Pump；
* 日志聚合。

## 8.3 MPMC Queue

用途：

* Fixed Pool 全局队列；
* Work-Stealing 外部 injection；
* Blocking Executor；
* Worker Task Queue。

首版优先实现：

* 有界 ring buffer；
* 明确的 full 策略；
* 批量 push/pop；
* cache-line padding；
* Debug sequence 检查。

## 8.4 Work-Stealing Deque

采用 owner push/pop、其他 Worker steal 的模型：

```zig
pub const WorkStealingDeque = struct {
    top: std.atomic.Value(usize),
    bottom: std.atomic.Value(usize),
    buffer: *Buffer,
};
```

首版使用固定容量：

```text
本地 deque 满
   → 转入全局 injection queue
```

暂不在首版实现动态扩容，以避免旧 buffer 回收时引入复杂的 epoch 或 hazard pointer 问题。

---

# 9. Executor 抽象

## 9.1 核心接口

```zig
pub const Executor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        submit: *const fn (
            ptr: *anyopaque,
            task: *Task,
            options: SubmitOptions,
        ) SubmitError!void,

        workerCount: *const fn (*const anyopaque) usize,

        isWorkerThread: *const fn (*const anyopaque) bool,

        helpUntil: *const fn (
            ptr: *anyopaque,
            condition: WaitCondition,
        ) void,
    };
};
```

## 9.2 Task

底层 Task 不使用堆闭包作为唯一实现：

```zig
pub const Task = struct {
    next: ?*Task = null,

    run_fn: *const fn (
        task: *Task,
        context: *WorkerContext,
    ) void,

    state: std.atomic.Value(u32),
    flags: TaskFlags,
    trace_id: u64,
};
```

业务 Task intrusive 地嵌入：

```zig
const PhysicsTask = struct {
    task: Task,
    world: *PhysicsWorld,
    begin: usize,
    end: usize,

    fn run(base: *Task, ctx: *WorkerContext) void {
        const self: *PhysicsTask =
            @fieldParentPtr("task", base);

        self.world.solveRange(
            self.begin,
            self.end,
            ctx.scratch,
        );
    }
};
```

上层再提供泛型包装：

```zig
try executor.spawn(updatePhysics, .{ world, dt }, .{
    .name = "Physics.Update",
});
```

## 9.3 Executor 类型

### InlineExecutor

同步执行，适用于：

* 测试；
* 单线程模式；
* 确定性执行；
* 无线程平台；
* 调试数据竞争。

### SerialExecutor

单个专用线程 + MPSC 队列，适用于：

* 渲染提交；
* 日志刷盘；
* 数据库写；
* 受线程约束的第三方 API。

### FixedThreadPool

全局 MPMC 队列 + 固定 Worker，适用于：

* 第一阶段实现；
* 中粗粒度工具任务；
* Blocking Pool 基础；
* Work-Stealing 对照测试。

### WorkStealingExecutor

最终 CPU 主执行器。

### BlockingExecutor

运行允许长时间阻塞的任务，与 Compute Worker 隔离。

### PumpExecutor

本身不创建线程，由 Main/Render 线程调用：

```zig
runtime.main.drain(.{
    .max_tasks = 128,
    .time_budget_ns = 1_000_000,
});
```

### DeterministicExecutor

单线程或固定调度序列，支持 record/replay。

---

# 10. Work-Stealing Job System

## 10.1 Worker 数据结构

```zig
pub const Worker = struct {
    id: WorkerId,

    high_queue: WorkStealingDeque,
    normal_queue: WorkStealingDeque,
    background_queue: WorkStealingDeque,

    scratch: ScratchAllocator,
    task_cache: TaskCache,

    rng_state: u64,
    sleep_state: std.atomic.Value(u32),
    stats: WorkerStats,
};
```

全局结构：

```zig
pub const WorkStealingExecutor = struct {
    workers: []Worker,
    threads: []std.Thread,

    injection_queue: MpmcQueue,
    urgent_queue: MpmcQueue,

    sleeping_workers: std.atomic.Value(u32),
    shutdown_state: std.atomic.Value(u32),

    wake_semaphore: Semaphore,
};
```

## 10.2 任务获取顺序

```text
1. pop 本地 critical/high
2. pop 本地 normal
3. 检查全局 urgent
4. 检查全局 injection
5. steal 其他 Worker high
6. steal 其他 Worker normal
7. 执行 background
8. spin
9. yield
10. park
```

## 10.3 唤醒策略

提交任务时：

```text
若没有睡眠 Worker
    → 不执行系统唤醒

若任务新增了可利用并行度
    → 唤醒一个或有限数量 Worker
```

批量提交：

```text
wake_count =
    min(new_parallelism, sleeping_worker_count)
```

禁止每次提交都唤醒全部线程。

## 10.4 Worker 等待

Worker 等待子任务时不能直接阻塞：

```zig
pub fn wait(
    executor: *WorkStealingExecutor,
    counter: *Counter,
) void {
    if (!executor.isCurrentWorker()) {
        counter.blockingWait();
        return;
    }

    while (!counter.isDone()) {
        if (executor.tryExecuteOne()) continue;
        executor.shortPark(counter);
    }
}
```

原则：

> Worker 等待时继续帮助执行其他任务。

否则 fork-join 容易发生线程池饥饿甚至死锁。

---

# 11. Scope、Counter 和错误传播

## 11.1 Counter

```zig
pub const Counter = struct {
    remaining: std.atomic.Value(u32),
    event: Event,
};
```

适用于一组 Job 的完成同步。

## 11.2 Scope

```zig
try executor.scope(struct {
    fn run(scope: *Scope, world: *World) !void {
        for (world.islands) |island| {
            try scope.spawn(
                solveIsland,
                .{island},
                .{},
            );
        }
    }
}.run, .{world});
```

Scope 返回前保证：

* 所有子任务结束；
* 捕获变量仍有效；
* 错误已传播；
* 取消已完成收敛。

## 11.3 ScopePolicy

```zig
pub const ScopePolicy = enum {
    wait_all,
    cancel_on_first_error,
    collect_errors,
};
```

默认：

```text
cancel_on_first_error
+
wait for all started children
```

## 11.4 Cancellation

取消是协作式的：

```zig
pub const CancellationToken = struct {
    state: *const std.atomic.Value(u32),

    pub fn isCancelled(self: CancellationToken) bool;
};
```

不支持强制杀死 Worker 线程。

---

# 12. 任务内存管理

## 12.1 Frame Task Arena

游戏帧任务使用：

```text
Frame N 分配
Frame N 全部完成
整块 reset
```

可采用三缓冲 Arena，以适应多帧在途。

## 12.2 Worker Local Cache

通用任务使用：

```text
Global Slab
   → Worker 批量领取
   → Worker Local Free List
```

降低 allocator contention。

## 12.3 Inline Payload

Task 可内置小 payload：

```zig
pub const SmallTask = struct {
    task: Task,
    payload_size: u8,
    payload: [48]u8 align(16),
};
```

超过容量时显式使用外部 storage。

## 12.4 生命周期等级

提供两类句柄：

```text
Safe TaskHandle
    slot + generation

ScopedTaskHandle
    作用域内裸指针
```

高性能引擎内部可使用 Scoped 版本；公开和跨模块 API 默认使用 generational handle。

---

# 13. 并行算法层

提供：

* `parallelFor`；
* `parallelForRange`；
* `parallelInvoke`；
* `parallelReduce`；
* `parallelScan`；
* `parallelSort`；
* `pipeline`。

示例：

```zig
try parallel.forRange(
    runtime.compute,
    0,
    entities.len,
    .{ .grain = .auto },
    updateEntities,
    .{ world, dt },
);
```

## 13.1 Grain Size

默认目标不是“一元素一任务”，而是：

```text
task_count =
    worker_count × oversubscription

oversubscription:
    默认 4～8
```

自动 grain 可使用历史采样：

```text
estimated_ns_per_item
target_task_duration
```

初始目标任务时长建议为几十微秒量级，最终以实际平台 benchmark 为准。

---

# 14. Local Task Graph

## 14.1 定位

Local Task Graph 表示一次进程内执行 DAG：

* 图在内存中；
* 节点通常执行一次；
* 进程退出后不恢复；
* 节点可以持有指针；
* 目标是低开销；
* 依赖主要由显式边表达。

适用：

* 一帧游戏任务；
* 一次 Profiler 分析；
* 一次工具处理；
* 单进程构建阶段；
* 一次复杂计算 pipeline。

## 14.2 节点

```zig
pub const LocalTaskNode = struct {
    id: NodeId,
    task: Task,

    remaining_dependencies: std.atomic.Value(u32),
    dependents: []NodeId,

    state: std.atomic.Value(LocalTaskState),
};
```

```zig
pub const LocalTaskState = enum {
    pending,
    ready,
    running,
    completed,
    failed,
    cancelled,
};
```

## 14.3 构图

```zig
const load = graph.addTask("Load", loadFn);
const decode = graph.addTask("Decode", decodeFn);
const upload = graph.addTask("Upload", uploadFn);

graph.dependsOn(decode, load);
graph.dependsOn(upload, decode);
```

## 14.4 编译

编译阶段执行：

* Node ID 验证；
* 环检测；
* 入度计算；
* dependents 压缩；
* executor target 解析；
* trace metadata 生成。

## 14.5 执行

```text
remaining_dependencies == 0
       → Ready
       → 投递到目标 Executor
       → 完成
       → dependents.fetchSub(1)
       → 新的 Ready Node
```

## 14.6 Executor Target

```zig
pub const LocalExecutionTarget = union(enum) {
    compute,
    blocking,
    main,
    render,
    serial: ExecutorId,
};
```

---

# 15. Resource-Based Task Graph

## 15.1 定位

Resource Graph 解决的不是单纯“先 A 后 B”，而是：

* 哪些任务读写同一资源；
* 哪些范围发生冲突；
* 哪个任务产生资源的新版本；
* 哪些任务可以复用缓存；
* 当前内存、磁盘、网络和 CPU 预算允许运行哪些任务；
* 如何让整张图的完成时间最短。

它是独立于 Local Task Graph 的模块，但最终可把单个 Ready Resource Task 投递给 Executor 或一个小型 Local Graph。

## 15.2 ResourceKey

资源 Identity 使用结构体，不强制暴露为单一 Hash：

```zig
pub const ResourceKey = union(enum) {
    file: FileKey,
    page: PageKey,
    memory_buffer: BufferKey,
    database_segment: DbSegmentKey,
    gpu_buffer: GpuBufferKey,
    texture: TextureKey,
    network_blob: NetworkBlobKey,
    custom: CustomResourceKey,
};
```

Page Key：

```zig
pub const PageKey = struct {
    file_hash: u128,
    block_index: u32,
    page_index: u32,
};
```

内部可以缓存 hash 以提升查找速度，但：

> Hash 不是逻辑资源标识本身。

## 15.3 ResourceRange

```zig
pub const ResourceRange = union(enum) {
    whole,

    byte_range: struct {
        offset: u64,
        size: u64,
    },

    page_range: struct {
        first: u32,
        count: u32,
    },

    texture_range: TextureSubresourceRange,
    custom: CustomRange,
};
```

## 15.4 AccessMode

首版支持：

```zig
pub const AccessMode = enum {
    read,
    write,
    create,
    delete,
};
```

后续支持：

* append；
* reduce；
* atomic；
* commute。

访问冲突条件：

```text
ResourceKey 相同
AND Range 重叠
AND 至少一方为排他写访问
```

## 15.5 ResourceAccess

```zig
pub const ResourceAccess = struct {
    resource: ResourceKey,
    range: ResourceRange = .whole,
    mode: AccessMode,
    version: VersionConstraint = .latest,
};
```

## 15.6 自动依赖生成

每个 Resource/Range 维护 frontier：

```zig
pub const ResourceFrontier = struct {
    last_writer: ?NodeId,
    active_readers: SmallNodeSet,
};
```

处理 read：

```text
依赖 last_writer
加入 active_readers
```

处理 write/create/delete：

```text
依赖 last_writer
依赖 active_readers
清空 active_readers
last_writer = current
```

自动生成：

* RAW；
* WAR；
* WAW。

## 15.7 范围索引

Whole Resource 可使用单一 frontier。

Range Resource 建议分阶段实现：

### Phase 1

* page 级 key；
* 每 page 独立资源；
* 避免复杂 interval tree。

### Phase 2

* interval tree；
* segment tree；
* range splitting；
* 相邻区间 coalescing。

对于数据库 page，优先把 page 作为独立 ResourceKey，而不是先实现任意 byte-range hazard。

---

# 16. Resource Version 和增量执行

## 16.1 版本模型

```text
Resource R@0
  → Task A
Resource R@1
  → Task B
Resource R@2
```

```zig
pub const ResourceVersion = struct {
    key: ResourceKey,
    generation: u64,
    content_hash: ?u256,
    state: ResourceState,
};
```

## 16.2 Task Fingerprint

```text
Task Fingerprint =
    task kind/version
  + normalized parameters
  + input resource version/hash
  + toolchain version
  + relevant environment
```

命中缓存时：

* 跳过任务执行；
* 从本地缓存恢复；
* 从远程缓存下载；
* 直接注册 Output Version。

## 16.3 缓存等级

```text
L0: 当前执行内存缓存
L1: 本机磁盘缓存
L2: 项目共享缓存
L3: COS 远程 Artifact Cache
```

COS 只承担 Artifact/Blob 存储，不承担强一致 Workflow History。

---

# 17. Resource Scheduler 和预算模型

## 17.1 ResourceCost

```zig
pub const ResourceCost = struct {
    cpu_units: u16 = 0,
    blocking_threads: u16 = 0,

    memory_bytes: u64 = 0,

    disk_read_units: u16 = 0,
    disk_write_units: u16 = 0,

    network_units: u16 = 0,
    gpu_copy_units: u16 = 0,

    device_id: ?DeviceId = null,
};
```

## 17.2 ExecutionBudget

```zig
pub const ExecutionBudget = struct {
    cpu_units: u32,
    blocking_threads: u32,
    memory_bytes: u64,

    disk_devices: []DeviceBudget,

    network_units: u32,
    gpu_copy_units: u32,
};
```

## 17.3 Ready 与 Runnable 分离

```text
Dependencies Satisfied
          → Ready

Ready + Budget Available
          → Runnable

Runnable
          → Executor
```

依赖完成不代表立即执行。

## 17.4 设备感知

限制应按物理设备或 backend 建立：

```text
NVMe-0
    read concurrency: 8
    write concurrency: 4

HDD-0
    read concurrency: 2
    write concurrency: 1

COS
    download concurrency: 16
    upload concurrency: 8
```

不同项目和机器性能等级允许覆盖默认值。

## 17.5 调度评分

```text
score =
    critical_path_score
  + downstream_unlock_score
  + memory_release_score
  + locality_score
  + age_score
  - resource_pressure_penalty
```

优先任务示例：

* 位于关键路径；
* 完成后能释放大量内存；
* 能解锁大量下游；
* 与当前磁盘访问位置相近；
* 已等待较长时间。

## 17.6 Task Fusion

编译或执行前合并：

* 连续 page delete；
* 连续 page read；
* 同 pack 的小修改；
* 批量 stat；
* 批量数据库写；
* 批量 COS metadata 请求；
* 批量 GPU copy。

---

# 18. Resource Graph 事务与提交

涉及包文件、索引或数据库更新时，最终状态不能在任务执行中途对外可见。

推荐流程：

```text
Prepare
  → 生成临时资源版本
  → 校验
  → Build Index
  → Commit Record
  → 原子切换 Current Version
  → 回收旧版本
```

## 18.1 Commit Group

```zig
pub const CommitGroup = struct {
    id: StableId,
    input_versions: []ResourceVersionId,
    output_versions: []ResourceVersionId,
    commit_policy: CommitPolicy,
};
```

## 18.2 崩溃恢复

启动时扫描：

* Prepared but not committed；
* Commit record 存在但切换未完成；
* 临时文件；
* 不可达 resource version；
* 待回收旧 page。

原则：

> 资源任务执行可以重试，但最终版本切换必须具备明确的事务边界。

---

# 19. ECS 架构

## 19.1 ECS 目标

* 高吞吐顺序遍历；
* Cache-friendly；
* Chunk 级并行；
* System 访问冲突自动调度；
* 支持结构变化；
* 支持 Snapshot、Rollback 和网络复制；
* 不依赖并发 HashMap 作为组件主存储；
* 可与自研物理、渲染和脚本系统集成。

## 19.2 Entity ID

```zig
pub const Entity = packed struct(u64) {
    index: u32,
    generation: u32,
};
```

Entity Slot：

```zig
pub const EntitySlot = struct {
    generation: u32,
    location: EntityLocation,
    alive: bool,
};
```

Location：

```zig
pub const EntityLocation = struct {
    archetype_id: ArchetypeId,
    chunk_index: u32,
    row: u16,
};
```

`Entity.index` 直接索引 slot table，不使用 HashMap 查询位置。

## 19.3 Component Registry

```zig
pub const ComponentMeta = struct {
    id: ComponentTypeId,
    stable_name: []const u8,

    size: u32,
    alignment: u16,

    init_fn: ?InitFn,
    deinit_fn: ?DeinitFn,
    move_fn: MoveFn,
    clone_fn: ?CloneFn,

    schema_version: u32,
    flags: ComponentFlags,
};
```

Component ID 必须稳定，避免：

* Save 数据失效；
* 网络协议漂移；
* 插件加载顺序改变 ID；
* 热更新后无法识别旧组件。

推荐通过 build-time manifest 生成。

---

# 20. Archetype 和 Chunk

## 20.1 Archetype Signature

```zig
pub const ArchetypeSignature = struct {
    words: []const u64,
};
```

规模较小时可使用固定 bitset。

Archetype Lookup：

```text
hash(signature)
  → candidate bucket
  → exact signature compare
```

HashMap 只用于组件集合到 Archetype 的低频查找，而不是组件数据的主存储。

## 20.2 Chunk

```zig
pub const Chunk = struct {
    archetype: *Archetype,
    count: u16,
    capacity: u16,

    entities: [*]Entity,
    storage: []align(64) u8,

    column_versions: []ChangeVersion,
};
```

推荐从 32 KiB chunk 起步，通过 benchmark 决定最终值。

## 20.3 Chunk Layout

```text
Chunk Header
Entity Column
Position Column
Rotation Column
Velocity Column
...
```

每个组件列：

* 按 alignment 对齐；
* 连续存储；
* 使用 SoA；
* 可直接拆成 SIMD 或并行 range。

## 20.4 外部组件

以下数据只在 ECS 中保存 Handle：

* Mesh；
* Texture；
* GPU Buffer；
* 大型动态数组；
* 脚本对象；
* 地址必须稳定的第三方对象。

```zig
pub const MeshComponent = struct {
    mesh: ResourceHandle(MeshResource),
};
```

---

# 21. ECS 结构变化

添加或删除组件会迁移 Archetype：

```text
A = [Position, Velocity]
       + Health
B = [Position, Velocity, Health]
```

迁移步骤：

1. 查找或创建目标 Archetype；
2. 在目标 Chunk 分配 row；
3. move 共有组件；
4. init 新增组件；
5. deinit 删除组件；
6. swap-remove 源 row；
7. 更新被移动 Entity Location；
8. 更新当前 Entity Location。

## 21.1 Archetype Edge Cache

```zig
pub const ArchetypeEdges = struct {
    add: AutoHashMap(ComponentTypeId, ArchetypeId),
    remove: AutoHashMap(ComponentTypeId, ArchetypeId),
};
```

避免重复计算目标 signature。

## 21.2 Deferred Command Buffer

并行 System 运行期间禁止直接迁移 Entity。

```zig
pub const EcsCommand = union(enum) {
    create: CreateCommand,
    destroy: Entity,
    add_component: AddComponentCommand,
    remove_component: RemoveComponentCommand,
    set_component: SetComponentCommand,
};
```

每 Worker 一个 Command Buffer：

```text
Worker Local Commands
    → Batch Barrier
    → Merge
    → Validate
    → Apply Structural Changes
```

## 21.3 Command 冲突

同一 Entity 同一阶段可能出现：

* destroy + add；
* add + remove；
* 多次 set；
* destroy 两次。

需要定义确定规则：

1. Destroy 优先；
2. 同组件 add/remove 由 command sequence 决定；
3. Debug 模式报告冲突；
4. 可选 deterministic sort；
5. Release 模式仍保证结果稳定。

---

# 22. ECS Query

## 22.1 QueryDesc

```zig
pub const QueryDesc = struct {
    required: ComponentMask,
    excluded: ComponentMask,
    optional: ComponentMask,
    changed: ComponentMask,
};
```

易用层：

```zig
const query = world.query(.{
    .read = .{ Position, Velocity },
    .write = .{ Transform },
    .without = .{ Disabled },
});
```

## 22.2 QueryPlan

```zig
pub const QueryPlan = struct {
    matched_archetypes: []ArchetypeId,
    column_bindings: []ColumnBinding,
    observed_archetype_version: u64,
};
```

World 新增 Archetype 时：

```text
world.archetype_version++
```

QueryPlan 只增量检查新 Archetype，不每帧扫描全部 Archetype。

## 22.3 Chunk View

```zig
while (query.nextChunk()) |chunk| {
    const positions = chunk.read(Position);
    const velocities = chunk.read(Velocity);
    const transforms = chunk.write(Transform);

    for (0..chunk.count) |i| {
        transforms[i] =
            integrate(positions[i], velocities[i]);
    }
}
```

---

# 23. ECS System Scheduler

## 23.1 SystemDesc

```zig
pub const SystemDesc = struct {
    id: SystemId,
    name: []const u8,

    component_reads: ComponentMask,
    component_writes: ComponentMask,

    resource_reads: EcsResourceMask,
    resource_writes: EcsResourceMask,

    before: []const SystemId,
    after: []const SystemId,

    phase: PhaseId,
    target: SystemTarget,

    run_fn: SystemRunFn,
};
```

这里的 ECS Resource 是 singleton：

* Time；
* Input；
* Physics World；
* Render Scene；
* Network Context。

它与 Resource Task Graph 中的文件、page 和 GPU artifact 是不同类型体系。

## 23.2 冲突判定

System A 和 B 可并行，当：

```text
A.write ∩ B.read  = ∅
A.write ∩ B.write = ∅
B.write ∩ A.read  = ∅
```

同时满足：

* singleton resource 无冲突；
* phase 允许并行；
* before/after 不冲突；
* target thread 允许并行。

## 23.3 CompiledSchedule

```zig
pub const CompiledSchedule = struct {
    phases: []CompiledPhase,
};

pub const CompiledPhase = struct {
    batches: []SystemBatch,
};
```

示例：

```text
PreUpdate
  Batch 0:
    Input
    NetworkReceive

Update
  Batch 0:
    AI
    AnimationSampling

  Batch 1:
    Movement

  Batch 2:
    Physics

PostUpdate
  Batch 0:
    TransformPropagation
    RenderExtract
```

## 23.4 两级并行

```text
System-Level Parallelism
      +
Chunk-Level Parallelism
```

执行：

```text
同一 Batch 中互不冲突的 System 并行
每个 System 将匹配 Chunk 切成 Chunk Range Task
```

避免一个 Chunk 一个 Job 造成任务数量爆炸：

```text
小 Query
  → 单 Task

大 Query
  → 多个 Chunk Range Task
```

## 23.5 Schedule 编译时机

仅在以下情况重编：

* 新增或删除 System；
* Access 声明变化；
* Phase 配置变化；
* 插件加载；
* 显式依赖变化。

新增 Archetype 只更新 QueryPlan。

---

# 24. ECS 并发写入规则

## 24.1 Chunk 临时所有权

一个写入 Chunk 的 Job 在执行期间拥有对应列或整个 Chunk 的独占权。

通常采用：

```text
一个可写 Chunk
同一时刻只交给一个 Job
```

无需在组件实例上加 Mutex。

## 24.2 随机跨 Chunk 写

例如 Projectile 修改其他 Entity 的 Health。

不建议直接随机写。

推荐三类方案：

### Event Buffer

```text
Projectile System
  → DamageEvent
  → Merge/Sort
  → DamageApply System
```

### Partitioned Inbox

```text
owner_partition =
    entity.index % partition_count
```

每个 partition 由固定 Job 处理。

### 明确的 Atomic Component

仅用于极少数字段，例如累计计数，不作为默认方案。

---

# 25. ECS Change Detection

```zig
pub const ChangeVersion = u32;
```

World Tick：

```text
world.change_tick++
```

写入列后：

```text
chunk.column_version[Transform]
    = world.change_tick
```

System 保存：

```text
system.last_run_tick
```

Changed Query：

```text
column_version newer than last_run_tick
```

需要使用 wrapping arithmetic 处理 tick 回绕。

默认采用 Chunk/Column 级版本，只有必要时才增加 entity 级 dirty bit。

---

# 26. ECS Event 模型

区分：

## 26.1 Immediate Event

仅在当前调用栈内使用，不跨任务。

## 26.2 Frame Event

Worker Local Buffer：

```text
System produces events
  → Merge
  → Next System/Phase consumes
```

## 26.3 Persistent Game Event

需要：

* 保存；
* 网络复制；
* 重放；
* 跨服务器传输。

这类事件进入独立 Gameplay Event/Workflow/消息基础设施，不能复用 ECS 临时 Frame Event Buffer 作为持久存储。

---

# 27. ECS Snapshot、Rollback 和复制

## 27.1 Snapshot 格式

```text
World Header
Component Schema Table
Archetype Table
Chunk Data
Entity Location Data
External Handle References
```

按：

```text
Archetype
  → Chunk
  → Component Column
```

序列化，而不是逐 Entity 动态反射。

## 27.2 Incremental Snapshot

记录：

* 新 Entity；
* 删除 Entity；
* Archetype Migration；
* Changed Column；
* External Resource Handle 变化。

## 27.3 Rollback

```text
Frame N Snapshot
  + N+1 Inputs/Commands
  + N+2 Inputs/Commands
```

Rollback 到 N 后重新执行。

确定性还需要：

* 稳定迭代顺序；
* 固定随机种子；
* 浮点策略；
* 无数据竞争；
* 确定性 Command Merge。

---

# 28. Durable Workflow

## 28.1 定位

跨进程异步流程使用 Durable Workflow：

* 登录；
* 匹配；
* 角色迁移；
* 跨服；
* 支付；
* 长时间资源生产；
* 机器农场跨机器任务；
* Agent 长流程。

Temporal 的公开架构将 Workflow Execution 建模为可恢复执行单元，为每个执行维护 append-only event history，并可通过 replay 恢复状态；Workflow Task 会产生命令，例如启动 Timer、调度 Activity 或启动 Child Workflow。该模型可作为本模块的重要参考，但不要求原样复刻 Temporal 的全部服务规模。

## 28.2 核心原则

* Workflow Logic 必须确定性；
* 真实副作用放入 Activity；
* History append-only；
* Timer 持久化；
* Activity 至少一次投递；
* Activity Handler 必须幂等；
* Workflow 允许循环、等待、重试和补偿；
* Workflow Definition 有版本。

---

# 29. Workflow 数据模型

## 29.1 WorkflowDefinition

```zig
pub const WorkflowDefinition = struct {
    id: WorkflowDefinitionId,
    stable_name: []const u8,
    version: u32,

    state_schema: SchemaId,
    event_schema: SchemaId,
    command_schema: SchemaId,

    transition_fn: TransitionFn,
};
```

## 29.2 WorkflowInstance

```zig
pub const WorkflowInstance = struct {
    id: WorkflowId,

    definition_id: WorkflowDefinitionId,
    definition_version: u32,

    status: WorkflowStatus,

    next_event_seq: u64,
    state_version: u64,
    owner_epoch: u64,

    created_at: i64,
    updated_at: i64,
};
```

## 29.3 WorkflowStatus

```zig
pub const WorkflowStatus = enum {
    running,
    waiting,
    compensating,
    completed,
    failed,
    cancelled,
    terminated,
};
```

## 29.4 Event History

```zig
pub const WorkflowEventEnvelope = struct {
    workflow_id: WorkflowId,
    sequence: u64,

    event_id: EventId,
    event_type: u32,
    schema_version: u32,

    timestamp: i64,
    trace_context: TraceContext,

    payload: []const u8,
};
```

事件包括：

* WorkflowStarted；
* SignalReceived；
* ActivityScheduled；
* ActivityStarted；
* ActivityHeartbeat；
* ActivityCompleted；
* ActivityFailed；
* TimerCreated；
* TimerFired；
* ChildWorkflowStarted；
* WorkflowCompleted；
* WorkflowFailed；
* CancellationRequested；
* CompensationScheduled。

---

# 30. Workflow Logic 和 Activity

## 30.1 Workflow Logic

只能：

* 读取历史和逻辑状态；
* 处理输入事件；
* 产生 Command；
* 读取由框架提供的逻辑时间；
* 使用由框架记录的确定性随机值。

禁止直接：

* 网络请求；
* 数据库写；
* 文件访问；
* 获取系统当前时间；
* 调用不确定随机数；
* 读取进程全局可变状态。

## 30.2 Activity

Activity 执行副作用：

* RPC；
* DB；
* Session 创建；
* Server Allocation；
* Token 签发；
* COS 上传下载；
* 文件转换；
* 通知客户端；
* 发送消息。

```zig
pub const ActivityHandler = *const fn (
    context: *ActivityContext,
    input: []const u8,
) anyerror!ActivityResult;
```

Activity 可被重复投递，因此需要幂等键。

## 30.3 ActivityKey

```zig
pub const ActivityKey = struct {
    workflow_id: WorkflowId,
    command_sequence: u64,
};
```

业务服务存储：

```text
ActivityKey → Completed Result
```

重复请求返回原结果，而不是重复产生副作用。

---

# 31. Workflow Transition

显式状态机接口：

```zig
pub const TransitionResult = struct {
    new_state: []const u8,
    commands: []WorkflowCommand,
    status: WorkflowStatus,
};

pub const TransitionFn = *const fn (
    context: *WorkflowContext,
    state: []const u8,
    event: WorkflowEventEnvelope,
) anyerror!TransitionResult;
```

首版优先使用显式状态机，不实现持久化 Zig 调用栈或 Fiber。

原因：

* 编译器版本变化；
* 函数地址不可持久化；
* Stack Layout 不稳定；
* 代码升级困难；
* 调试和审计复杂；
* 显式协议状态机更适合登录业务。

---

# 32. Workflow Command

```zig
pub const WorkflowCommand = union(enum) {
    schedule_activity: ScheduleActivity,
    start_timer: StartTimer,
    cancel_timer: CancelTimer,

    send_signal: SendSignal,
    start_child: StartChildWorkflow,
    cancel_child: CancelChildWorkflow,

    complete: CompleteWorkflow,
    fail: FailWorkflow,
};
```

Command 与新 History Event 在同一事务中提交。

---

# 33. Workflow Persistence

## 33.1 表结构建议

### workflow_instance

```text
workflow_id
definition_id
definition_version
status
next_event_seq
state_version
owner_epoch
created_at
updated_at
```

### workflow_history

```text
workflow_id
sequence
event_id
event_type
schema_version
payload
timestamp
trace_context
```

唯一键：

```text
(workflow_id, sequence)
event_id UNIQUE
```

### workflow_task

```text
task_id
workflow_id
expected_state_version
available_at
lease_owner
lease_epoch
lease_expire_at
attempt
```

### activity_task

```text
activity_id
workflow_id
command_sequence
activity_type
payload
available_at
attempt
lease...
```

### durable_timer

```text
workflow_id
timer_id
fire_at
status
```

### workflow_snapshot

```text
workflow_id
event_sequence
definition_version
state_payload
checksum
```

### inbox / outbox

用于可靠消息收发。

## 33.2 事务边界

Workflow Task 完成时，在单一数据库事务中：

1. 验证 expected state version；
2. append 新 history events；
3. 更新 instance；
4. 写 Activity Task；
5. 写 Timer；
6. 写 Outbox；
7. 提交。

失败则整体回滚。

---

# 34. Workflow Scheduler

## 34.1 组件

```text
Workflow Frontend
History Store
Workflow Scheduler
Workflow Task Queue
Activity Task Queue
Timer Service
Workflow Worker
Activity Worker
Outbox Publisher
Operator API
```

MVP 可放入同一个服务进程，但模块边界保持独立。

## 34.2 Worker Lease

Task 拉取时获得 lease：

```text
lease_owner
lease_epoch
lease_expire_at
```

完成时必须携带 epoch，防止旧 Worker 在 lease 过期后覆盖新 Worker 的结果。

## 34.3 Workflow Task

Workflow Task 的职责：

```text
读取 Snapshot + 新 History
  → Replay
  → 执行 Transition
  → 产生 Commands
  → 原子提交
```

它不执行真实 RPC。

## 34.4 Activity Task

```text
Poll
  → Execute Side Effect
  → Heartbeat
  → Complete/Fail
  → 转换为 Workflow Event
```

---

# 35. Durable Timer

Timer 必须持久化。

```zig
pub const DurableTimer = struct {
    workflow_id: WorkflowId,
    timer_id: TimerId,
    fire_at_utc_ms: i64,
    status: TimerStatus,
};
```

MVP：

* 数据库索引；
* 分区；
* `FOR UPDATE SKIP LOCKED` 或等效机制；
* 批量扫描；
* append `TimerFired`；
* 创建 Workflow Task。

规模扩大后可增加：

* 分层时间轮；
* 分区最小堆；
* 缓存索引；
* 独立 Timer Service。

数据库仍是事实来源，内存结构只用于加速。

---

# 36. 重试和超时

## 36.1 RetryPolicy

```zig
pub const RetryPolicy = struct {
    initial_interval_ms: u64,
    backoff_coefficient: f32,
    max_interval_ms: u64,
    max_attempts: u32,

    non_retryable_errors: []ErrorCode,
};
```

## 36.2 Timeout 类型

* Schedule-to-Start；
* Start-to-Close；
* Heartbeat；
* Workflow Execution Timeout；
* Workflow Idle Timeout；
* Signal Wait Timeout。

## 36.3 错误分类

```zig
pub const FailureClass = enum {
    retryable,
    non_retryable,
    cancelled,
    timeout,
    business_rejection,
    bug,
};
```

业务错误和系统错误必须区分：

```text
PasswordWrong
    → business rejection

AuthServiceUnavailable
    → retryable

InvalidWorkflowState
    → bug/non-retryable
```

---

# 37. Inbox、Outbox 和消息语义

## 37.1 Outbox

业务状态修改和 Outbox 写入同一事务。

Publisher 异步发送，成功后标记。

## 37.2 Inbox

接收端：

```text
message_id UNIQUE
```

处理前或处理事务中写 Inbox，重复消息直接跳过。

## 37.3 语义

推荐明确声明：

```text
Workflow History Commit:
    optimistic concurrency + effectively once

Activity Delivery:
    at least once

External Side Effect:
    idempotency required

Signals:
    deduplicated by message/event ID
```

不承诺无法实际保证的通用端到端 exactly-once。

---

# 38. 登录 Workflow 示例

## 38.1 状态

```zig
pub const LoginState = enum {
    created,
    authenticating,
    loading_account,
    waiting_role_selection,
    allocating_server,
    creating_session,
    notifying_client,
    waiting_client_ack,
    compensating,
    completed,
    failed,
};
```

## 38.2 正常流程

```text
Client Login Request
    → Authenticate Activity
    → Load Account Activity
    → Wait/Validate Role Selection
    → Allocate Game Server Activity
    → Create Session Activity
    → Send Login Result Activity
    → Start Client Ack Timer
    → Client Ack Signal
    → Complete
```

## 38.3 断线重连

```text
Client Disconnect
    → Workflow 保持 waiting_client_ack
    → Session 暂时保留
    → Client 携带 reconnect token
    → Signal Workflow
    → 重发已有 SessionInfo
```

不能默认重新创建 Session。

## 38.4 补偿

若已分配服务器但 Session 创建失败：

```text
Release Server Allocation
```

若已创建 Session 但最终超时：

```text
Revoke Session
  → Release Allocation
```

补偿是新的 Activity，不是跨服务数据库回滚。

---

# 39. Workflow 版本升级

每个实例固定：

```text
definition_id
definition_version
```

支持三种策略：

## 39.1 保留旧 Worker

旧实例继续运行旧版本，最安全。

## 39.2 显式状态迁移

```zig
pub fn migrate(
    from_version: u32,
    to_version: u32,
    state: []const u8,
) ![]const u8;
```

## 39.3 版本 Marker

在 History 中记录某个逻辑分支采用的版本。

首版建议：

> 实例固定 Definition Version，必要时显式迁移。

禁止让已有 History 静默运行全新逻辑。

---

# 40. Workflow Snapshot 和归档

History 是事实来源，Snapshot 是性能优化。

恢复流程：

```text
Load Latest Snapshot
  + Replay Events After Snapshot
```

Snapshot 包含：

* Workflow ID；
* Event Sequence；
* Definition Version；
* State Payload；
* Checksum。

大 Payload：

* 存对象存储；
* History 仅保存 Artifact ID、Hash 和 Schema；
* 定期归档已完成 Workflow；
* 按业务合规要求设置保留期限。

---

# 41. 三种图与 Workflow 的边界

| 维度   | Local Task Graph | Resource Task Graph | Durable Workflow      |
| ---- | ---------------- | ------------------- | --------------------- |
| 生命周期 | μs～分钟            | ms～小时               | 秒～数月                  |
| 存储   | 内存               | 内存 + Artifact 状态    | 持久数据库                 |
| 结构   | DAG              | 资源版本 DAG            | 可循环状态机                |
| 节点   | 本地函数             | 资源转换                | Transition / Activity |
| 崩溃恢复 | 通常无              | 重新规划或缓存恢复           | 必须恢复                  |
| 依赖   | 显式边              | Resource Hazard     | Event/Signal/Timer    |
| 调度目标 | 低延迟              | 最短 makespan         | 可靠性                   |
| 指针   | 允许               | 本地执行允许              | 禁止持久化                 |
| 重试   | 通常图级             | 节点级                 | 策略化 Activity Retry    |
| 版本升级 | 不需要              | Fingerprint         | Definition Version    |
| 取消   | Atomic Token     | 图传播                 | Persistent Event      |

---

# 42. ECS 与三类执行框架的关系

```text
ECS Compiled Schedule
    → 产生 System/Chunk Jobs
    → Compute Executor

Resource Graph
    → Ready Resource Node
    → Local Task 或 Executor

Durable Workflow
    → Schedule Activity
    → Activity Worker
    → 可在本地运行 Resource Graph
    → Executor

Local Task Graph
    → Executor
```

禁止反向依赖：

* Executor 不知道 ECS；
* Executor 不知道 ResourceKey；
* Executor 不知道 Workflow；
* Local Task Graph 不管理持久定时器；
* ECS Schedule 不承担文件 Hazard；
* Resource Graph 不承担客户端登录状态机。

---

# 43. `std.Io` 集成

Zig 0.16 的 `std.Io` 提供 Future、Group 以及 async/concurrent 相关接口，并允许不同后端决定并发执行方式。为应对标准库持续演进，本框架应把 `std.Io` 放在 Adapter 后面。

```zig
pub const Runtime = struct {
    compute: WorkStealingExecutor,
    blocking: BlockingExecutor,
    main: PumpExecutor,
    render: PumpExecutor,

    io: IoAdapter,
};
```

## 43.1 I/O Completion

```zig
pub const IoCompletion = struct {
    task: Task,
    result: IoResult,
    continuation_executor: ExecutorId,
};
```

流程：

```text
Compute Task
  → Submit Async I/O
  → Worker 继续执行其他任务
  → I/O Completion
  → Continuation 投回 Compute
```

禁止：

```text
Compute Worker
  → 长时间同步阻塞 I/O
```

无法异步化的 API 进入 Blocking Executor。

---

# 44. 可观测性

## 44.1 Trace Context

```zig
pub const TraceContext = struct {
    trace_id: StableId,
    span_id: u64,
    parent_span_id: ?u64,
};
```

传播链：

```text
Workflow
  → Activity
  → Resource Graph
  → Local Task Graph
  → Executor Task
  → Worker
```

## 44.2 Executor Event

* TaskCreated；
* TaskEnqueued；
* TaskStarted；
* TaskFinished；
* TaskStolen；
* WorkerSleep；
* WorkerWake；
* WaitBegin；
* WaitEnd；
* QueueOverflow。

## 44.3 ECS Event

* SystemStart/End；
* Query Chunk Count；
* Chunk Job；
* Command Merge；
* Archetype Migration；
* Schedule Stall；
* Access Conflict。

## 44.4 Resource Graph Event

* NodeReady；
* BudgetBlocked；
* CacheHit；
* CacheMiss；
* ResourceVersionCreated；
* Commit；
* ResourceReleased；
* CriticalPathChanged。

## 44.5 Workflow Event

* WorkflowTaskLatency；
* ActivityAttempt；
* RetryScheduled；
* TimerLag；
* SignalLatency；
* HistoryLength；
* ReplayDuration；
* LeaseExpired。

## 44.6 输出

* Chrome Trace；
* Tracy；
* 自研 Profiler 二进制流；
* Web Inspector；
* Prometheus 风格 metrics；
* Agent 分析接口。

---

# 45. Inspector 和管理界面

统一管理平台可展示：

## Executor

* Worker 利用率；
* Queue Depth；
* Steal Rate；
* Idle Time；
* Task Latency；
* Blocking Worker 数量。

## ECS

* Entity 数；
* Archetype 数；
* Chunk Occupancy；
* System Timeline；
* Query 扫描量；
* Structural Change 数；
* System 冲突图。

## Resource Graph

* DAG；
* Ready/Running/Blocked；
* 关键路径；
* CPU/IO/Memory 使用；
* Cache Hit；
* 当前资源版本；
* Commit 状态。

## Workflow

* Workflow Instance；
* 当前状态；
* Event History；
* Pending Activity；
* Timer；
* Retry；
* Compensation；
* Signal；
* Replay 和 Debug。

---

# 46. 确定性和重放

## 46.1 Executor Replay

支持：

```zig
pub const SchedulerMode = enum {
    parallel,
    single_threaded,
    deterministic,
    record,
    replay,
};
```

记录：

* Task Ready 顺序；
* Worker 选择；
* Steal 结果；
* Command Merge 顺序；
* 随机种子。

## 46.2 ECS Replay

需要记录：

* Input；
* Network Event；
* Random Seed；
* Structural Command；
* External authoritative data。

## 46.3 Workflow Replay

Workflow Logic 通过 History 重放，要求：

* 确定性 Transition；
* 版本固定；
* 所有副作用都来自已记录 Activity Result；
* 时间来自 Timer/Event；
* 随机数由框架记录。

---

# 47. 安全和隔离

## 47.1 Executor Task

* 捕获生命周期检查；
* Debug generation；
* Task poison；
* stack size 限制；
* Blocking Task 分类；
* shutdown 后禁止提交。

## 47.2 ECS

* Component Registry 校验；
* Query access 校验；
* System 声明与实际访问一致；
* Debug 借用追踪；
* stale Entity 检测；
* Command Buffer schema 校验。

## 47.3 Workflow

* Payload 大小限制；
* Schema 白名单；
* Activity 权限；
* Tenant/Namespace；
* Workflow 操作审计；
* Signal 授权；
* Replay 资源限制；
* History 长度限制；
* 敏感字段加密或脱敏。

---

# 48. Shutdown 模型

## 48.1 Executor ShutdownPolicy

```zig
pub const ShutdownPolicy = enum {
    drain,
    cancel_pending,
    immediate,
};
```

默认使用 `drain`。

## 48.2 Runtime Shutdown 顺序

```text
停止接收新 Workflow/Graph
  → Workflow Worker 停止 Poll
  → 等待或释放 Activity Lease
  → Resource Graph 停止新 Plan
  → ECS 停止 Update
  → Drain Main/Render
  → Drain Compute
  → Drain Blocking
  → Flush Trace/Log
  → Destroy Threads
```

Durable Workflow 未完成状态留在数据库，进程重启后恢复。

---

# 49. 测试方案

## 49.1 并发基础

* Queue wrap-around；
* 满/空并发；
* 最后一个 deque 元素竞争；
* 多 producer；
* shutdown 与 submit；
* Worker sleep/wake；
* Counter race；
* Scope error；
* Cancel race。

## 49.2 Executor 压力测试

随机操作：

* submit；
* spawn child；
* wait；
* steal；
* cancel；
* yield；
* shutdown。

执行百万级迭代。

## 49.3 Local Task Graph

* 环检测；
* 大量 fan-in/fan-out；
* failure propagation；
* executor routing；
* cancel；
* empty graph；
* dynamic build failure。

## 49.4 Resource Graph

* RAW/WAR/WAW；
* range overlap；
* delete/create；
* budget starvation；
* aging；
* task fusion；
* cache hit；
* commit crash recovery；
* out-of-memory；
* 多设备 limiter。

## 49.5 ECS

* Entity generation；
* Archetype migration；
* swap-remove location；
* Add/Remove 冲突；
* Query cache 增量更新；
* Chunk 并行；
* System conflict；
* Snapshot/Restore；
* Rollback；
* deterministic command merge。

## 49.6 Workflow

* Crash before commit；
* Crash after commit before ACK；
* duplicate Activity Result；
* duplicate Signal；
* lease expiry；
* timer duplicate fire；
* retry backoff；
* compensation；
* snapshot replay；
* definition version mismatch；
* outbox/inbox；
* DB failover。

## 49.7 Sanitizer 和 Debug

平台允许时加入：

* AddressSanitizer；
* ThreadSanitizer；
* UndefinedBehaviorSanitizer；
* Debug Allocator；
* Poison Memory；
* Queue Canary；
* Model-based concurrency test。

---

# 50. Benchmark 方案

## 50.1 Executor

任务耗时：

* 空任务；
* 1 μs；
* 10 μs；
* 100 μs；
* 1 ms。

场景：

* 外部集中提交；
* Worker 递归 spawn；
* 不均匀任务；
* 高 fan-in；
* 高 fan-out；
* blocking 混入；
* 单线程；
* 多 NUMA。

指标：

* submit latency；
* p50/p95/p99；
* throughput；
* steal rate；
* idle ratio；
* CPU utilization；
* memory per task。

## 50.2 ECS

* 顺序遍历带宽；
* Query 编译；
* Query cache；
* 结构变化；
* Chunk size；
* Entity 数；
* Archetype 数；
* System-level parallelism；
* Chunk-level parallelism；
* Snapshot；
* Random access event 模式。

## 50.3 Resource Graph

* 构图时间；
* Hazard 推导时间；
* Ready Queue 开销；
* makespan；
* CPU/IO overlap；
* peak memory；
* cache hit；
* range index；
* fusion 收益。

## 50.4 Workflow

* Workflow Task throughput；
* History append latency；
* replay latency；
* snapshot interval；
* Activity Poll；
* timer lag；
* lease contention；
* signal latency；
* DB storage growth。

---

# 51. 分阶段实施路线

## Phase 0：Core 和 Platform

实现：

* ID；
* Clock；
* Schema；
* Thread Wrapper；
* Affinity；
* Priority；
* Event；
* Semaphore；
* SPSC/MPSC；
* Trace 基础。

## Phase 1：基础 Executor

实现：

* Task；
* InlineExecutor；
* SerialExecutor；
* FixedThreadPool；
* BlockingExecutor；
* PumpExecutor；
* Counter；
* Scope；
* Cancellation；
* 基础 Parallel For。

此阶段即可服务工具和 Agent。

## Phase 2：Work-Stealing

实现：

* bounded deque；
* Worker Local Cache；
* injection queue；
* help-while-wait；
* priority；
* batch submit；
* deterministic mode；
* benchmark。

## Phase 3：Local Task Graph

实现：

* Builder；
* DAG compile；
* cycle detection；
* Node dependency counter；
* executor routing；
* cancellation；
* graph tracing。

## Phase 4：ECS Core

实现：

* Entity；
* Component Registry；
* Archetype；
* Chunk；
* Query；
* Migration；
* Deferred Commands；
* 单线程 Schedule。

## Phase 5：ECS Parallel

实现：

* System Access；
* Schedule Compiler；
* System Batch；
* Chunk Range Job；
* Worker Local Event/Command；
* Change Detection；
* Snapshot。

## Phase 6：Resource Graph MVP

实现：

* ResourceKey；
* page/file resource；
* read/write/create/delete；
* Hazard Dependency；
* Resource Version；
* cost/budget；
* Executor Routing；
* Commit Group；
* Trace。

## Phase 7：Resource Graph 增量化

实现：

* Fingerprint；
* Local Cache；
* COS Cache；
* task fusion；
* critical path；
* dynamic cost model；
* range resource；
* crash recovery。

## Phase 8：Durable Workflow MVP

实现：

* Definition；
* Instance；
* explicit state machine；
* History；
* Workflow Task；
* Activity；
* Retry；
* Timer；
* Signal；
* Snapshot；
* Inbox/Outbox；
* Operator API。

## Phase 9：Workflow 分布式化

实现：

* Partition；
* Lease/Epoch；
* Worker Queue；
* Child Workflow；
* Compensation；
* Version Migration；
* Archival；
* 多服务部署；
* 高可用。

---

# 52. 首版非目标

首版不实现：

* Stackful Fiber；
* 任意优先级实时调度；
* 完整 NUMA Scheduler；
* 任意 byte-range 高性能 interval hazard；
* 通用 distributed transaction；
* 端到端 exactly-once；
* ECS 全量反射编辑器；
* 持久化 Zig 协程栈；
* 多 Region 强一致 Workflow；
* 自动把所有业务代码转换为 Workflow；
* 一个统一的 Generic Graph Node。

这些能力应在实际数据证明必要后增加。

---

# 53. 推荐关键 API

## Runtime

```zig
var runtime = try Runtime.init(allocator, .{
    .compute = .{
        .worker_count = null,
        .local_queue_capacity = 4096,
    },
    .blocking = .{
        .min_threads = 1,
        .max_threads = 8,
    },
});

defer runtime.deinit(.drain);
```

## ECS

```zig
var world = try ecs.World.init(allocator, .{
    .chunk_bytes = 32 * 1024,
});

try world.registerComponent(Position);
try world.registerComponent(Velocity);

try world.registerSystem(.{
    .name = "Movement",
    .component_reads = maskOf(.{Velocity}),
    .component_writes = maskOf(.{Position}),
    .run_fn = movementSystem,
});

try world.compileSchedule();
try world.update(&runtime, dt);
```

## Local Task Graph

```zig
var graph = LocalTaskGraph.init(frame_allocator);

const a = try graph.addTask("A", runA);
const b = try graph.addTask("B", runB);

try graph.dependsOn(b, a);

var plan = try graph.compile();
try plan.execute(&runtime);
```

## Resource Graph

```zig
var graph = ResourceGraph.init(allocator);

try graph.addTask(.{
    .name = "DecompressPage",

    .accesses = &.{
        ResourceAccess.read(compressed_page),
        ResourceAccess.create(raw_page),
    },

    .cost = .{
        .cpu_units = 1,
        .memory_bytes = page_size * 3,
    },

    .run_fn = decompressPage,
});

var plan = try graph.compile();
try plan.execute(&runtime, budgets);
```

## Workflow

```zig
try workflow_registry.register(
    "game.login",
    3,
    LoginWorkflow,
);

const workflow_id = try workflow_client.start(
    "game.login",
    3,
    login_request,
);

try workflow_client.signal(
    workflow_id,
    "client.reconnected",
    reconnect_info,
);
```

---

# 54. 最终技术决策

| 范畴                | 决策                                 |
| ----------------- | ---------------------------------- |
| 基础线程              | `std.Thread` + 自研平台扩展              |
| CPU Executor      | Work-Stealing                      |
| 外部提交              | MPMC Injection Queue               |
| 本地队列              | Bounded Work-Stealing Deque        |
| Worker 等待         | Help-While-Wait                    |
| 阻塞任务              | 独立 Blocking Executor               |
| I/O               | `std.Io` Adapter                   |
| 任务分配              | Frame Arena + Worker Local Slab    |
| Local Graph       | 显式内存 DAG                           |
| Resource Graph    | 独立资源版本与预算调度                        |
| Resource Identity | 结构体 Key                            |
| ECS               | Archetype + Chunk + SoA            |
| ECS 并发            | System Access + Chunk Ownership    |
| ECS 结构修改          | Deferred Command Buffer            |
| 跨进程流程             | Durable Event-Driven State Machine |
| 副作用               | Activity                           |
| 消息语义              | At-Least-Once + Idempotency        |
| Timer             | 持久化 Timer                          |
| Workflow 状态       | History + Snapshot                 |
| 调试                | Trace + Record/Replay              |
| Fiber             | 延后                                 |

---

# 55. 最终架构结论

本方案建立的是一套分层执行基础设施，而不是单一线程池或单一任务图：

```text
Durable Workflow
    负责跨进程、持久化、重试和长生命周期状态

Resource Task Graph
    负责资源访问、版本、增量、缓存和多预算调度

ECS
    负责游戏对象数据布局、Query 和 System 并行

Local Task Graph
    负责进程内低开销 DAG

Executor Runtime
    负责 Worker、线程和任务实际执行

Platform/Sync
    负责内核线程、原子、等待和平台能力
```

最重要的工程边界是：

1. ECS 不使用 DashMap 风格组件存储；
2. ECS 并发由访问声明和 Chunk 所有权保证；
3. Local Task Graph 只表达进程内完成依赖；
4. Resource Graph 独立表达 Resource Hazard、Version 和 Budget；
5. Durable Workflow 使用持久事件状态机，而不是 DAG；
6. Workflow 副作用必须通过幂等 Activity；
7. CPU、Blocking 和 I/O 执行域必须隔离；
8. 所有系统共享底层设施，但不共享节点和调度器；
9. 可观测性、确定性和故障注入必须从第一版设计；
10. 先实现简单可靠的 FixedPool、ECS Core 和显式状态机，再逐步增加 Work-Stealing、增量缓存和分布式能力。

该架构能够作为游戏引擎、资源系统、自动化 Agent、机器农场和游戏在线服务的统一执行底座，同时避免为了表面复用而把完全不同的执行语义耦合到同一套实现中。
