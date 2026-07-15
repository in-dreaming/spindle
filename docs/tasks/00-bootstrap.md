# 00 — 工程骨架、构建与 CI

## 前置

只需 `setup.md`。本任务是所有其他任务的唯一入口，不实现并发框架业务能力。

## 目标

建立 Zig 0.16.0 可复现工程、模块边界、统一测试命令和三平台 CI，使后续任务可以只添加实现与测试。

## 实现范围

1. 创建 `build.zig`、`build.zig.zon`、`src/root.zig`。
2. 创建 `setup.md` 固定布局中全部模块目录及聚合 `root.zig`；空模块只能导出空 namespace，不得声明虚假 API。
3. 构建一个名为 `spindle` 的静态库模块，并添加 `examples/smoke.zig`，证明外部程序可 `@import("spindle")`。
4. 建立 `tests/unit.zig`、`tests/integration/root.zig`、`tests/stress/root.zig` 和 `bench/root.zig` 聚合入口。
5. 在 `build.zig` 实现 `check`、`test`、`test-stress`、`test-postgres`、`bench`、`test-all` 步骤。当前 `test-postgres` 可在未设置数据库参数时输出明确 skip 原因并成功；任务 16 会替换为真实测试。
6. 添加 `.github/workflows/ci.yml`：
   - 固定 Zig 0.16.0；
   - Windows、Ubuntu、macOS 执行 `zig build test-all`；
   - Ubuntu ReleaseFast 执行 benchmark smoke（不设性能门槛）；
   - 缓存只缓存 Zig 下载和 `.zig-cache`，缓存失效不能影响正确性。
7. 更新 `README.md`，只写已存在的构建、测试命令和当前模块状态，不宣称未实现能力。
8. 添加 `docs/contributing.md`，记录格式化、测试、随机种子重放、依赖和模块导入规则。

## 已决策接口

- 最低且唯一受支持编译器：Zig 0.16.0。
- 库导入名：`spindle`。
- `src/root.zig` 仅聚合公开模块，禁止包含平台初始化副作用。
- 测试默认单进程可运行；压力测试必须有默认上限，并可通过构建选项提高迭代数。

## 不做

- 不提前定义 Executor/ECS/Graph/Workflow 类型。
- 不添加第三方测试框架。
- 不以生成空测试报告、吞掉编译错误或只检查文件存在来冒充验证。

## 验证

```text
zig version                    # 必须为 0.16.0
zig fmt --check build.zig src tests bench examples
zig build check
zig build test
zig build test-stress
zig build bench -Doptimize=ReleaseFast
zig build test-all
```

专项断言：

- smoke 示例真实链接 `spindle`；
- 任意模块聚合入口可独立被根模块解析；
- Debug、ReleaseSafe、ReleaseFast 均可构建；
- CI YAML 的三平台矩阵和固定版本可由 action linter/实际 CI 解析。

## 验收清单

- [ ] 六个统一构建步骤均存在且行为与 `setup.md` 一致。
- [ ] 无未使用的伪 API、占位测试或 TODO。
- [ ] README 不超前宣传。
- [ ] 三平台 CI 覆盖 Debug 测试，ReleaseFast benchmark 可启动。
- [ ] `zig build test-all` 通过。

