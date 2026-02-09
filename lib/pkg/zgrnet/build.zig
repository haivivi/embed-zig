// build.zig — For local development only (zig build / zig build test).
//
// Bazel builds use BUILD.bazel with embed-zig's Bazel-native rules
// (@embed_zig//bazel/zig:defs.bzl) and do NOT depend on this file.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (noise core only — higher modules not yet genericized)
    const lib_module = b.createModule(.{
        .root_source_file = b.path("src/noise.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library
    const lib = b.addLibrary(.{
        .name = "zgrnet",
        .root_module = lib_module,
    });
    b.installArtifact(lib);

    // Export module for dependents
    _ = b.addModule("zgrnet", .{
        .root_source_file = b.path("src/noise.zig"),
    });

    // Tests
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/noise.zig"),
        .target = target,
        .optimize = optimize,
    });

    const main_tests = b.addTest(.{
        .root_module = test_module,
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);
}
