const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const stress_iterations = b.option(u32, "stress-iterations", "Iterations used by bounded stress tests") orelse 128;
    const test_filter = b.option([]const u8, "test-filter", "Run only tests whose names contain this text");
    const task_graph_enabled = b.option(bool, "task-graph", "Build the local task graph") orelse true;
    const ecs_enabled = b.option(bool, "ecs", "Build ECS storage and scheduling") orelse false;
    const resource_graph_enabled = b.option(bool, "resource-graph", "Build the resource graph") orelse false;
    const workflow_enabled = b.option(bool, "workflow", "Build the database-independent workflow protocol") orelse true;
    const workflow_sqlite_enabled = b.option(bool, "workflow-sqlite", "Build the embedded SQLite workflow store") orelse false;
    const workflow_archive_enabled = b.option(bool, "workflow-archive", "Build local workflow history archival") orelse false;
    const workflow_archive_http_enabled = b.option(bool, "workflow-archive-http", "Build HTTP workflow archive transport") orelse false;
    if (resource_graph_enabled and !task_graph_enabled) @panic("-Dresource-graph=true implies -Dtask-graph=true");
    if (workflow_sqlite_enabled and !workflow_enabled) {
        @panic("-Dworkflow-sqlite=true implies -Dworkflow=true; do not disable workflow");
    }
    if (workflow_archive_enabled and !workflow_sqlite_enabled) @panic("-Dworkflow-archive=true implies -Dworkflow-sqlite=true");
    if (workflow_archive_http_enabled and !workflow_archive_enabled) @panic("-Dworkflow-archive-http=true implies -Dworkflow-archive=true");
    if (workflow_archive_http_enabled and !resource_graph_enabled) @panic("-Dworkflow-archive-http=true implies -Dresource-graph=true");

    const base_options = b.addOptions();
    base_options.addOption(bool, "task_graph", task_graph_enabled);
    base_options.addOption(bool, "ecs", ecs_enabled);
    base_options.addOption(bool, "resource_graph", resource_graph_enabled);
    base_options.addOption(bool, "workflow", workflow_enabled);
    base_options.addOption(bool, "workflow_sqlite", workflow_sqlite_enabled);
    base_options.addOption(bool, "workflow_archive", workflow_archive_enabled);
    base_options.addOption(bool, "workflow_archive_http", workflow_archive_http_enabled);

    const spindle = b.addModule("spindle", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    spindle.addOptions("build_options", base_options);
    if (workflow_sqlite_enabled) configureSqlite(b, spindle, target, optimize);

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
    addProfileExamples(b, check, target, optimize, spindle, task_graph_enabled, ecs_enabled, resource_graph_enabled);

    const model_options = featureOptions(b, true, true, true, true, false, false, false);
    const model_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    model_module.addOptions("build_options", model_options);
    const unit_tests = addTest(b, "tests/unit.zig", target, optimize, model_module);
    const integration_tests = addTest(b, "tests/integration/root.zig", target, optimize, model_module);
    const runtime_tests = addTest(b, "tests/integration/runtime_integration.zig", target, optimize, spindle);
    const recovery_tests = addTest(b, "tests/integration/resource_recovery.zig", target, optimize, model_module);
    const artifact_http_tests = addTest(b, "tests/integration/artifact_http.zig", target, optimize, model_module);
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
    test_step.dependOn(&b.addRunArtifact(runtime_tests).step);
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

    const sqlite_step = b.step("test-sqlite", "Run real SQLite workflow persistence tests");
    const sqlite_options = b.addOptions();
    sqlite_options.addOption(bool, "task_graph", true);
    sqlite_options.addOption(bool, "ecs", false);
    sqlite_options.addOption(bool, "resource_graph", false);
    sqlite_options.addOption(bool, "workflow", true);
    sqlite_options.addOption(bool, "workflow_sqlite", true);
    sqlite_options.addOption(bool, "workflow_archive", false);
    sqlite_options.addOption(bool, "workflow_archive_http", false);
    const sqlite_module = b.addModule("spindle_sqlite", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    sqlite_module.addOptions("build_options", sqlite_options);
    configureSqlite(b, sqlite_module, target, optimize);
    const sqlite_tests = addFilteredTest(b, "tests/integration/workflow_sqlite.zig", target, optimize, sqlite_module, test_filter);
    const sqlite_test_dependency = b.lazyDependency("sqlite_amalgamation", .{}) orelse @panic("SQLite dependency is required by test-sqlite");
    sqlite_tests.root_module.addIncludePath(sqlite_test_dependency.path("."));
    const login_fixture = b.createModule(.{ .root_source_file = b.path("tests/fixtures/login_workflow.zig"), .target = target, .optimize = optimize });
    login_fixture.addImport("spindle", sqlite_module);
    sqlite_tests.root_module.addImport("login_workflow", login_fixture);
    const crash_fixture = b.addExecutable(.{ .name = "workflow-crash-worker", .root_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/workflow_crash_worker.zig"), .target = target, .optimize = optimize }) });
    crash_fixture.root_module.addImport("spindle", sqlite_module);
    crash_fixture.root_module.addImport("login_workflow", login_fixture);
    const sqlite_test_options = b.addOptions();
    sqlite_test_options.addOptionPath("crash_fixture", crash_fixture.getEmittedBin());
    sqlite_tests.root_module.addOptions("build_options", sqlite_test_options);
    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);
    sqlite_step.dependOn(&run_sqlite_tests.step);
    const archive_options = b.addOptions();
    archive_options.addOption(bool, "task_graph", true);
    archive_options.addOption(bool, "ecs", false);
    archive_options.addOption(bool, "resource_graph", false);
    archive_options.addOption(bool, "workflow", true);
    archive_options.addOption(bool, "workflow_sqlite", true);
    archive_options.addOption(bool, "workflow_archive", true);
    archive_options.addOption(bool, "workflow_archive_http", false);
    const archive_module = b.addModule("spindle_archive", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    archive_module.addOptions("build_options", archive_options);
    configureSqlite(b, archive_module, target, optimize);
    const archive_tests = addTest(b, "tests/integration/workflow_archive.zig", target, optimize, archive_module);
    const archive_login_fixture = b.createModule(.{ .root_source_file = b.path("tests/fixtures/login_workflow.zig"), .target = target, .optimize = optimize });
    archive_login_fixture.addImport("spindle", archive_module);
    archive_tests.root_module.addImport("login_workflow", archive_login_fixture);
    sqlite_step.dependOn(&b.addRunArtifact(archive_tests).step);
    const archive_http_options = b.addOptions();
    archive_http_options.addOption(bool, "task_graph", true);
    archive_http_options.addOption(bool, "ecs", false);
    archive_http_options.addOption(bool, "resource_graph", true);
    archive_http_options.addOption(bool, "workflow", true);
    archive_http_options.addOption(bool, "workflow_sqlite", true);
    archive_http_options.addOption(bool, "workflow_archive", true);
    archive_http_options.addOption(bool, "workflow_archive_http", true);
    const archive_http_module = b.addModule("spindle_archive_http", .{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    archive_http_module.addOptions("build_options", archive_http_options);
    configureSqlite(b, archive_http_module, target, optimize);
    const archive_http_tests = addTest(b, "tests/integration/workflow_archive_http_feature.zig", target, optimize, archive_http_module);
    sqlite_step.dependOn(&b.addRunArtifact(archive_http_tests).step);
    const workflow_off_options = b.addOptions();
    workflow_off_options.addOption(bool, "task_graph", true);
    workflow_off_options.addOption(bool, "ecs", false);
    workflow_off_options.addOption(bool, "resource_graph", false);
    workflow_off_options.addOption(bool, "workflow", false);
    workflow_off_options.addOption(bool, "workflow_sqlite", false);
    workflow_off_options.addOption(bool, "workflow_archive", false);
    workflow_off_options.addOption(bool, "workflow_archive_http", false);
    const workflow_off_module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
    workflow_off_module.addOptions("build_options", workflow_off_options);
    const workflow_off_tests = addTest(b, "tests/integration/workflow_feature_off.zig", target, optimize, workflow_off_module);
    sqlite_step.dependOn(&b.addRunArtifact(workflow_off_tests).step);
    const workflow_core_tests = addTest(b, "tests/integration/workflow_feature_core.zig", target, optimize, spindle);
    sqlite_step.dependOn(&b.addRunArtifact(workflow_core_tests).step);

    const test_all = b.step("test-all", "Run all validation suites");
    test_all.dependOn(check);
    test_all.dependOn(test_step);
    test_all.dependOn(stress_step);
    test_all.dependOn(sqlite_step);

    const matrix_step = b.step("test-feature-matrix", "Compile supported feature profiles and inspect optional imports");
    const artifact_inspector = b.addExecutable(.{ .name = "spindle-artifact-inspector", .root_module = b.createModule(.{ .root_source_file = b.path("tests/fixtures/artifact_inspector.zig"), .target = target, .optimize = optimize }) });
    const profiles = [_]struct { name: []const u8, task_graph: bool, ecs: bool, resource_graph: bool, workflow: bool, sqlite: bool, archive: bool, archive_http: bool }{
        .{ .name = "core", .task_graph = false, .ecs = false, .resource_graph = false, .workflow = false, .sqlite = false, .archive = false, .archive_http = false },
        .{ .name = "default", .task_graph = true, .ecs = false, .resource_graph = false, .workflow = true, .sqlite = false, .archive = false, .archive_http = false },
        .{ .name = "models", .task_graph = true, .ecs = true, .resource_graph = true, .workflow = true, .sqlite = false, .archive = false, .archive_http = false },
        .{ .name = "sqlite", .task_graph = true, .ecs = true, .resource_graph = true, .workflow = true, .sqlite = true, .archive = false, .archive_http = false },
        .{ .name = "archive_http", .task_graph = true, .ecs = true, .resource_graph = true, .workflow = true, .sqlite = true, .archive = true, .archive_http = true },
    };
    for (profiles) |profile| {
        const options = featureOptions(b, profile.task_graph, profile.ecs, profile.resource_graph, profile.workflow, profile.sqlite, profile.archive, profile.archive_http);
        const module = b.createModule(.{ .root_source_file = b.path("src/root.zig"), .target = target, .optimize = optimize });
        module.addOptions("build_options", options);
        if (profile.sqlite) configureSqlite(b, module, target, optimize);
        const profile_library = b.addLibrary(.{ .name = b.fmt("spindle-profile-{s}", .{profile.name}), .linkage = .static, .root_module = module });
        const inspect = b.addRunArtifact(artifact_inspector);
        inspect.addFileArg(profile_library.getEmittedBin());
        inspect.addArg(if (profile.sqlite) "+sqlite3_open_v2" else "-sqlite3_open_v2");
        inspect.addArg(if (profile.archive_http) "+archive_http" else "-archive_http");
        matrix_step.dependOn(&inspect.step);
        const matrix_tests = addTest(b, "tests/integration/feature_matrix.zig", target, optimize, module);
        matrix_step.dependOn(&b.addRunArtifact(matrix_tests).step);
    }
    test_all.dependOn(matrix_step);
}

fn featureOptions(b: *std.Build, task_graph: bool, ecs: bool, resource_graph: bool, workflow: bool, sqlite: bool, archive: bool, archive_http: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "task_graph", task_graph);
    options.addOption(bool, "ecs", ecs);
    options.addOption(bool, "resource_graph", resource_graph);
    options.addOption(bool, "workflow", workflow);
    options.addOption(bool, "workflow_sqlite", sqlite);
    options.addOption(bool, "workflow_archive", archive);
    options.addOption(bool, "workflow_archive_http", archive_http);
    return options;
}

fn addProfileExamples(b: *std.Build, check: *std.Build.Step, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spindle: *std.Build.Module, task_graph_enabled: bool, ecs_enabled: bool, resource_graph_enabled: bool) void {
    const examples = [_]struct { path: []const u8, enabled: bool }{
        .{ .path = "examples/executor_parallel.zig", .enabled = true },
        .{ .path = "examples/local_graph.zig", .enabled = task_graph_enabled },
        .{ .path = "examples/ecs.zig", .enabled = ecs_enabled },
        .{ .path = "examples/resource_graph.zig", .enabled = resource_graph_enabled },
    };
    for (examples) |example| if (example.enabled) {
        const executable = b.addExecutable(.{ .name = b.fmt("spindle-{s}", .{std.fs.path.stem(example.path)}), .root_module = b.createModule(.{ .root_source_file = b.path(example.path), .target = target, .optimize = optimize }) });
        executable.root_module.addImport("spindle", spindle);
        check.dependOn(&executable.step);
    };
}

fn addTest(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spindle: *std.Build.Module) *std.Build.Step.Compile {
    return addFilteredTest(b, path, target, optimize, spindle, null);
}

fn addFilteredTest(b: *std.Build, path: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, spindle: *std.Build.Module, filter: ?[]const u8) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        }),
        .filters = if (filter) |value| &.{value} else &.{},
    });
    tests.root_module.addImport("spindle", spindle);
    return tests;
}

fn configureSqlite(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const dependency = b.lazyDependency("sqlite_amalgamation", .{}) orelse @panic("SQLite dependency is required by -Dworkflow-sqlite=true");
    module.addImport("workflow_sqlite_migrations", b.createModule(.{ .root_source_file = b.path("db/migrations/root.zig"), .target = target, .optimize = optimize }));
    module.addIncludePath(dependency.path("."));
    module.addCSourceFile(.{ .file = dependency.path("sqlite3.c"), .flags = &.{ "-DSQLITE_THREADSAFE=1", "-DSQLITE_DEFAULT_SYNCHRONOUS=3", "-DSQLITE_OMIT_LOAD_EXTENSION" } });
    module.link_libc = true;
}
