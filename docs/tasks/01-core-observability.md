# 01 — Core、Schema 与基础可观测性

## 前置

完成 00；阅读 `docs/arch.md` 第 5、44、47、49 节。

## 目标

实现其余模块共享且不携带上层语义的稳定 ID、时钟、错误码、schema/codec registry、trace context 和低开销事件出口。

## 实现范围

- `core/id.zig`：泛型 `GenerationalId(Tag)`，slot generation 的比较、哈希、无效值和安全格式化。
- `core/stable_id.zig`：128 位 `StableId`，按时间排序的 UUIDv7 兼容生成、16 字节大端编码、规范字符串解析/格式化。生成器处理同毫秒并发、时钟回退和序号溢出，随机源由调用方提供。
- `core/clock.zig`：`Clock` vtable、SystemClock、线程安全 VirtualClock；明确 monotonic ns 与 UTC ms 单位。
- `core/error_code.zig`：稳定数值域、FailureClass、内部 error 到跨边界 envelope 的转换；未知码可往返保留。
- `core/hash.zig`：只暴露确定性内容哈希和进程随机 hash 的不同用途，禁止把随机 hash 写入持久格式。
- `core/schema.zig`、`core/registry.zig`：以稳定 schema ID + version + stable name 注册 codec/migration；拒绝重复 ID、重名异 ID、版本倒退和迁移断链。
- 定义二进制 envelope：magic、format version、schema ID/version、payload length、payload checksum；解析执行长度、溢出和上限检查。
- `observability/trace.zig`：`TraceContext`、span ID 生成、parent 传播。
- `observability/metrics.zig`：无锁/低锁 counter、gauge、histogram 快照；标签集合在注册时固定，禁止热路径动态分配。
- 提供通用 `EventSink`，禁用时零分配；首版实现内存 ring sink 和 NDJSON sink，供测试及后续模块接线。

## 关键语义

- 进程内 ID 与 StableId 类型不可隐式互转。
- registry 冻结后只读且可并发访问；冻结前注册不是线程安全 API。
- migration 只能逐版本执行并受 payload 上限约束；失败不改变目标 buffer。
- VirtualClock 只由测试显式推进，不使用 sleep。
- TraceContext 仅传播关联信息，不承担业务状态。

## 不做

- 不实现 ECS snapshot、workflow event 或 resource manifest 的具体 schema。
- 不实现 Chrome Trace、Tracy、Inspector 或 replay 调度。
- 不用 JSON 代替定义好的持久二进制 envelope。

## 验证

- GenerationalId stale/边界/hash 测试。
- StableId 并发生成至少百万个，无重复，字节序和字符串 round-trip，时钟回退时仍单生成器有序。
- Schema 重复、未知版本、迁移链、截断、畸形长度、checksum 错误、fuzz round-trip。
- SystemClock monotonic 非递减；VirtualClock 并发读/推进一致。
- EventSink 满队列策略可观测，不覆写未声明数据；NDJSON 可由标准解析器逐行读取。
- metrics 并发累计结果精确。

运行 `zig build test-all`，并为 envelope decoder 添加有界 fuzz/随机输入测试。

## 验收清单

- [ ] 所有持久字段单位、字节序、数值稳定性有文档和 golden bytes。
- [ ] registry 错误路径无泄漏，冻结后并发读取无锁或只读。
- [ ] 无上层模块反向依赖。
- [ ] 无固定 ID、固定随机数或仅测试可用的生产实现。
- [ ] 全量验证通过。

