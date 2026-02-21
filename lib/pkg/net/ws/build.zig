const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    const ws_mod = b.addModule("net/ws", .{
        .root_source_file = b.path("src/ws.zig"),
        .target = target,
        .optimize = optimize,
    });
    ws_mod.addImport("trait", trait_dep.module("trait"));

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ws.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // e2e tests
    const e2e_step = b.step("e2e", "Run e2e tests");
    const e2e_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    e2e_tests.root_module.addImport("ws", ws_mod);
    const run_e2e = b.addRunArtifact(e2e_tests);
    e2e_step.dependOn(&run_e2e.step);

    // Benchmarks
    const bench_step = b.step("bench", "Run benchmarks");
    const bench_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/bench_test.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    bench_tests.root_module.addImport("ws", ws_mod);
    const run_bench = b.addRunArtifact(bench_tests);
    bench_step.dependOn(&run_bench.step);
}
