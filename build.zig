const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zflame",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe_diff = b.addExecutable(.{
        .name = "diff-folded",
        .root_source_file = b.path("src/diff_folded.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Add zBench dependency
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });
    const zbench_module = zbench_dep.module("zbench");

    b.installArtifact(exe);
    b.installArtifact(exe_diff);

    const run_cmd = b.addRunArtifact(exe);
    const run_diff_cmd = b.addRunArtifact(exe_diff);
    run_cmd.step.dependOn(b.getInstallStep());
    run_diff_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
        run_diff_cmd.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const run_diff_step = b.step("run-diff", "Run the differential tool");
    run_diff_step.dependOn(&run_diff_cmd.step);

    // Main source tests.
    const exe_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Test files for all collapse parsers.
    const test_files = [_][]const u8{
        "src/test_collapse.zig",
    };

    const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

    // Add individual test steps for each collapse parser.
    for (test_files) |test_file| {
        const test_exe = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });

        const run_test = b.addRunArtifact(test_exe);
        run_exe_unit_tests.step.dependOn(&run_test.step);
    }

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);

    // Create module for zflame library
    const zflame_module = b.addModule("zflame", .{
        .root_source_file = b.path("src/main.zig"),
    });

    // Benchmark executables
    const bench_collapse = b.addExecutable(.{
        .name = "bench_collapse",
        .root_source_file = b.path("benchmarks/collapse.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_collapse.root_module.addImport("zbench", zbench_module);
    bench_collapse.root_module.addImport("zflame", zflame_module);

    const bench_flamegraph = b.addExecutable(.{
        .name = "bench_flamegraph",
        .root_source_file = b.path("benchmarks/flamegraph.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_flamegraph.root_module.addImport("zbench", zbench_module);
    bench_flamegraph.root_module.addImport("zflame", zflame_module);

    const run_bench_collapse = b.addRunArtifact(bench_collapse);
    const run_bench_flamegraph = b.addRunArtifact(bench_flamegraph);

    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&run_bench_collapse.step);
    bench_step.dependOn(&run_bench_flamegraph.step);
}
