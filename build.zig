const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stress_iterations = b.option(u32, "stress-iterations", "Iterations used by bounded stress tests") orelse 128;
    const postgres_url = b.option([]const u8, "postgres-url", "PostgreSQL connection URL for integration tests");
    const postgres_enabled = b.option(bool, "postgres", "Build PostgreSQL/libpq backend") orelse false;
    const postgres_dsn = postgres_url;

    const spindle = b.addModule("spindle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const library = b.addLibrary(.{
        .name = "spindle",
        .linkage = .static,
        .root_module = spindle,
    });
    b.installArtifact(library);

    const smoke = b.addExecutable(.{
        .name = "spindle-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    smoke.root_module.addImport("spindle", spindle);

    const check = b.step("check", "Compile the public library and smoke example");
    check.dependOn(&library.step);
    check.dependOn(&smoke.step);

    const unit_tests = addTest(b, "tests/unit.zig", target, optimize, spindle);
    const integration_tests = addTest(b, "tests/integration/root.zig", target, optimize, spindle);
    const recovery_tests = addTest(b, "tests/integration/resource_recovery.zig", target, optimize, spindle);
    const artifact_http_tests = addTest(b, "tests/integration/artifact_http.zig", target, optimize, spindle);
    const artifact_server_options = b.addOptions();
    artifact_server_options.addOption([]const u8, "server_script", b.pathFromRoot("tests/fixtures/artifact_http_server.ps1"));
    artifact_http_tests.root_module.addOptions("build_options", artifact_server_options);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    const run_integration_tests = b.addRunArtifact(integration_tests);
    const run_recovery_tests = b.addRunArtifact(recovery_tests);
    const run_artifact_http_tests = b.addRunArtifact(artifact_http_tests);
    const test_step = b.step("test", "Run unit and non-external-service integration tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_integration_tests.step);
    test_step.dependOn(&run_recovery_tests.step);
    test_step.dependOn(&run_artifact_http_tests.step);

    const fault_fixture = b.addExecutable(.{ .name = "resource-commit-fault", .root_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/resource_commit_fault.zig"), .target = target, .optimize = optimize }) });
    const fault_stages = [_][]const u8{ "before-record", "after-record", "after-pointer" };
    for (fault_stages) |stage| {
        const run_fault = b.addRunArtifact(fault_fixture);
        run_fault.addArg(stage);
        run_fault.addArg(b.fmt("spindle-task13-child-{s}", .{stage}));
        run_recovery_tests.step.dependOn(&run_fault.step);
    }

    const stress_options = b.addOptions();
    stress_options.addOption(u32, "iterations", stress_iterations);
    const stress_tests = addTest(b, "tests/stress/root.zig", target, optimize, spindle);
    stress_tests.root_module.addOptions("build_options", stress_options);
    const run_stress_tests = b.addRunArtifact(stress_tests);
    const stress_step = b.step("test-stress", "Run bounded, reproducible concurrency stress tests");
    stress_step.dependOn(&run_stress_tests.step);

    const bench = b.addExecutable(.{
        .name = "spindle-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench.root_module.addImport("spindle", spindle);
    const run_bench = b.addRunArtifact(bench);
    const bench_step = b.step("bench", "Run benchmark smoke workload");
    bench_step.dependOn(&run_bench.step);

    const postgres_step = b.step("test-postgres", "Run real PostgreSQL integration tests");
    // This target deliberately always links libpq: it never falls back to an in-memory or SQLite substitute.
    const postgres_tests = b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("tests/integration/workflow_postgres.zig"), .target = target, .optimize = optimize }) });
    postgres_tests.root_module.addImport("spindle", spindle);
    postgres_tests.root_module.addImport("workflow_postgres", b.createModule(.{ .root_source_file = b.path("src/zruntime/workflow/postgres.zig"), .target = target, .optimize = optimize }));
    postgres_tests.root_module.linkSystemLibrary("pq", .{});
    const run_postgres_tests = b.addRunArtifact(postgres_tests);
    if (postgres_dsn) |url| run_postgres_tests.setEnvironmentVariable("SPINDLE_TEST_PG_DSN", url);
    postgres_step.dependOn(&run_postgres_tests.step);

    const test_all = b.step("test-all", "Run all non-PostgreSQL validation suites");
    test_all.dependOn(check);
    test_all.dependOn(test_step);
    test_all.dependOn(stress_step);
    if (postgres_enabled or postgres_dsn != null) test_all.dependOn(postgres_step);
}

fn addTest(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spindle: *std.Build.Module) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("spindle", spindle);
    return tests;
}
