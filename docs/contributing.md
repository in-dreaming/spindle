# Contributing

This project requires Zig `0.16.0`. Format changed Zig files with `zig fmt`; before submitting, run `zig fmt --check build.zig src tests bench examples` and `zig build test-all`.

Stress tests must be bounded and reproducible. A test that uses randomness must print its seed on failure and accept that seed as a replay input. Do not make tests depend on wall-clock sleeps, execution order, or CPU count.

Use the standard library unless a dependency is necessary. Add every third-party dependency to `build.zig.zon` with its fixed content hash and document its license. Allocators are supplied by callers except for explicitly scoped temporary arenas.

Import another module only through its `root.zig` aggregate or a documented public type. Do not import private implementation files across module boundaries. New public APIs require `///` documentation covering thread safety, ownership, lifetime, cancellation, and error behavior.
