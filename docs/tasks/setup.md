# Spindle 实施统一上下文

本目录把 `docs/arch.md` 拆成可执行任务。实现 agent 必须先完整阅读本文件，再阅读且只执行被分配的任务文档；架构原文用于补充背景，若表述冲突，以本文件和任务文档中的“已决策约束”为准。

## 1. 当前基线

- 仓库目前只有 `README.md`、`LICENSE` 和 `docs/arch.md`，没有 Zig 工程、源码、依赖或测试基础设施。
- 语言和标准库固定为 Zig `0.16.0`，不得用旧版 API 猜测实现；以该版本随附的标准库源码和 `zig std` 为准。
- 包名为 `spindle`，公开入口为 `src/root.zig`，实现位于 `src/zruntime/<module>/`。
- 首批桌面目标为 Windows、Linux、macOS。平台专有实现必须有编译期分派，不能让不相关平台解析或链接专有符号。
- 架构包含四套独立上层语义：Local Task Graph、Resource Graph、ECS、Durable Workflow。它们可共享 core、executor、codec、clock、trace，但禁止共享节点、状态机、调度器和持久化模型。

## 2. 全局已决策约束

1. CPU、阻塞调用和异步 I/O 分别进入 Compute Executor、Blocking Executor 和 `std.Io` Adapter。
2. 默认采用结构化并发：Scope 返回前等待所有已启动子任务；首错触发协作取消，但仍等待收敛；逃逸任务只能走显式 detached API。
3. Executor 不得依赖 ECS、Resource Graph 或 Workflow；依赖方向只能从上层指向下层。
4. ECS 使用 generational Entity + Archetype + Chunk + SoA；组件主存储不得改成并发 HashMap；并发安全来自系统访问声明和 Chunk 所有权。
5. Local Task Graph 是一次性进程内 DAG；Resource Graph 依据资源 hazard、版本和预算调度；Workflow 是可循环的持久事件状态机。
6. Workflow logic 必须确定性且无副作用；副作用只在可幂等的 Activity 中；Activity 是 at-least-once，不宣传端到端 exactly-once。
7. Resource Graph MVP（任务 12—13）以 whole-resource 和 page-as-key 为准；byte-range interval index 只在增量阶段任务 14 实现。texture/custom range、动态 work-stealing deque、NUMA 调度、stackful fiber 均不在本轮。
8. 所有公开持久格式使用稳定 ID、显式 schema/version、固定字节序和校验；禁止持久化指针、函数地址、进程内 slot 或不稳定枚举序号。
9. 生产代码不得出现 `TODO`、`FIXME`、`unreachable` 代替正常错误处理、空函数、固定成功返回、睡眠模拟 I/O、仅为通过测试的分支或未接线实现。
10. 测试替身只允许用于可控时钟、故障注入和确定性调度，且必须实现与生产接口相同的状态转换；持久性、并发性和崩溃恢复验收必须使用真实线程、真实文件系统或真实 PostgreSQL。

## 3. 固定工程布局

```text
build.zig
build.zig.zon
src/
  root.zig
  zruntime/
    core/
    platform/
    sync/
    concurrent/
    executor/
    parallel/
    task_graph/
    ecs/
    resource_graph/
    workflow/
    io_adapter/
    observability/
    runtime/
    testing/
db/
  migrations/
tests/
  integration/
  stress/
  fixtures/
bench/
examples/
```

每个目录必须有一个聚合入口 `root.zig`。跨模块只能导入对方的 `root.zig` 或明确公开类型，不能绕过边界引用私有实现。

## 4. 公共工程规则

- 所有拥有资源的类型提供成对 `init/deinit`；失败路径不得泄漏线程、内存、文件句柄、lease 或数据库事务。
- allocator 由调用方注入；除明确的临时 arena 外，不隐藏全局 allocator。
- 时间统一注入 `core.Clock`：调度延迟用 monotonic 纳秒，持久 timer 用 UTC 毫秒。
- 错误跨持久/网络边界时转成稳定 `ErrorCode`；内部可保留 Zig error set。
- 原子内存序必须逐处注明同步关系；不能无理由统一使用 `seq_cst`，也不能以 `unordered` 掩盖竞态。
- Debug 构建启用 generation、owner、poison、边界和状态迁移断言；Release 构建仍必须保持正确性。
- 公共 API 需有 `///` 文档，说明线程安全、所有权、生命周期、取消与错误语义。
- 新增依赖必须通过 `build.zig.zon` 固定内容哈希，并说明许可证；标准库足够时不引入依赖。
- `CancellationSource`/`CancellationToken` 唯一定义在 `executor/cancellation.zig`；sync 只消费该接口，不得再定义同名类型。
- Detached API 由任务 04 交付，后续模块禁止私自创建 fire-and-forget 线程或任务。
- 格式化使用 `zig fmt`，测试不能依赖执行顺序、机器核数或墙钟 sleep。

## 5. 统一构建与验证契约

任务 `00` 必须建立以下稳定命令，后续任务不得另造入口：

```text
zig build check                 # 编译公开库和示例
zig build test                  # 单元测试与非外部服务集成测试
zig build test-stress           # 有界、可复现的并发压力测试
zig build test-postgres         # 启动要求由任务 16 文档定义，运行真实 PostgreSQL 集成测试
zig build bench -Doptimize=ReleaseFast
zig build test-all
```

`test-all` 至少包含 check、test、test-stress；从任务 16 起还必须在检测到测试数据库配置时包含 PostgreSQL 测试，CI 的 Linux 完整作业必须提供该配置。PostgreSQL CI 接线归任务 16。所有测试随机种子失败时必须打印并可用参数重放。

每个任务完成前：

1. 对改动文件执行 `zig fmt --check`（或先 `zig fmt` 再确认无差异）。
2. 运行该任务文档的专项验证。
3. 运行 `zig build test-all`，不得通过跳过、降低断言或屏蔽平台来获得绿色结果。
4. 检查所有新增公开 API 已从对应 `root.zig` 导出，且未制造反向依赖。
5. 在任务文档验收清单逐项核对；任何未完成项都表示任务未完成。

## 6. 任务依赖与执行顺序

| ID | 文档 | 直接依赖 |
|---|---|---|
| 00 | `00-bootstrap.md` | 无 |
| 01 | `01-core-observability.md` | 00 |
| 02 | `02-platform-sync.md` | 01 |
| 03 | `03-concurrent-containers.md` | 02 |
| 04 | `04-basic-executors.md` | 03 |
| 05 | `05-work-stealing.md` | 04 |
| 06 | `06-parallel-io.md` | 05 |
| 07 | `07-local-task-graph.md` | 05 |
| 08 | `08-ecs-storage.md` | 01 |
| 09 | `09-ecs-query-commands.md` | 08 |
| 10 | `10-ecs-scheduler.md` | 05、09 |
| 11 | `11-ecs-snapshot-replay.md` | 10 |
| 12 | `12-resource-graph-core.md` | 01、07 |
| 13 | `13-resource-scheduler-commit.md` | 12、05 |
| 14 | `14-resource-incremental.md` | 13、06 |
| 15 | `15-workflow-core.md` | 01 |
| 16 | `16-workflow-postgres.md` | 15 |
| 17 | `17-workflow-worker.md` | 05、15、16 |
| 18 | `18-activity-timer-messaging.md` | 17 |
| 19 | `19-workflow-distributed.md` | 18 |
| 20 | `20-workflow-child-compensation.md` | 19 |
| 21 | `21-workflow-migration-archival.md` | 20、14 |
| 22 | `22-runtime-integration.md` | 06、07、11、14、21 |

依赖满足后允许并行的主线：

- Executor：00 → 01 → 02 → 03 → 04 → 05 → 06/07
- ECS：01 → 08 → 09，随后与 Executor 汇合到 10 → 11
- Resource：07 → 12 → 13 → 14
- Workflow：01 → 15 → 16，随后与 Executor 汇合到 17 → 18 → 19 → 20，并与 ArtifactStore 汇合到 21
- 最终仅在所有主线完成后执行 22

一个 agent 一次只领取一个任务。不得顺手实现后续任务；确需调整已完成的公共接口时，必须保持兼容或同步更新其测试、文档和所有调用点。

## 7. 完成定义

“完成”不是类型和文件存在，而是：

- 正常、错误、取消、资源耗尽、shutdown 和并发竞争路径均有真实行为；
- 核心不变量有测试，涉及并发者有压力或模型测试；
- 涉及持久性者通过进程/连接重建验证恢复，而非在同一对象内模拟；
- 涉及跨平台者至少在 CI 对 Windows、Linux、macOS 编译，平台实现能运行的作业执行测试；
- benchmark 输出可机器读取的样本数、吞吐/延迟和环境信息，但性能阈值只在建立稳定基线后启用；
- 文档示例可编译，公开入口可被外部最小程序导入使用。

## 8. 架构原文的收敛解释

- `docs/arch.md` 的目录图是目标模块清单，不表示每个文件必须机械照搬；任务文档列出的路径是本轮实施边界。
- 架构提到 InlineExecutor 可用于“确定性执行”，但 Executor 调度 record/replay 由任务 05、ECS replay 由任务 11、Workflow history replay 由任务 15 实现；任务 22 只聚合 ReplayBundle。Inline 只保证调用线程同步执行。
- Resource Graph 的 range 类型可保留并验证 whole/page；MVP 对不支持的任意 byte/texture/custom range必须返回明确的 `UnsupportedRange`，不能静默按 whole 处理。
- 任务 14 完成后 byte_range 成为受支持范围；texture/custom range 仍返回 `UnsupportedRange`。
- Workflow MVP 和分布式阶段统一采用 PostgreSQL 16+ 作为事实存储，测试使用真实 PostgreSQL；对象存储仅保存大 payload/artifact，不保存 workflow history。
- `immediate` shutdown 仍不能强杀线程；它表示取消 pending、请求 running 协作取消并等待线程退出。
- Phase 路线中的“首版”只限定算法复杂度，不允许接口后面留空实现。
- 首版可观测性输出为 NDJSON、Chrome Trace、metrics snapshot 和 CLI inspector；Tracy、Prometheus exporter、自研 Web Inspector 为后续扩展。
- ECS 网络复制协议和 Web Inspector 不在本轮；ECS snapshot、rollback 和 replay 仍必须完整交付。
- `concurrent/epoch.zig` 是动态 deque/无锁回收的后续扩展，本轮不得创建空实现；Resource commit 的实际实现文件为 `resource_graph/commit.zig`。

