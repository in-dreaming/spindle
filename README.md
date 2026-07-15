# spindle

Spindle is a Zig runtime project under active construction. The current revision provides the reproducible Zig 0.16.0 project skeleton, public package entry point, module boundaries, test harnesses, and CI only.

## Commands

```text
zig build check
zig build test
zig build test-stress
zig build test-postgres
zig build bench -Doptimize=ReleaseFast
zig build test-all
```

Use `-Dstress-iterations=<count>` to raise the bounded stress-test iteration count. PostgreSQL integration tests are introduced by task 16; until then `zig build test-postgres` reports its explicit skip state.

## Module Status

`src/root.zig` exports aggregate namespaces for `core`, `platform`, `sync`, `concurrent`, `executor`, `parallel`, `task_graph`, `ecs`, `resource_graph`, `workflow`, `io_adapter`, `observability`, `runtime`, and `testing`. They are empty boundaries until their assigned implementation tasks are complete.
