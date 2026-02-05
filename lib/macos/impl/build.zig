const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const impl = b.addModule("impl", .{
        .root_source_file = b.path("src/impl.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Export crypto as separate module for convenience
    _ = b.addModule("crypto", .{
        .root_source_file = b.path("src/crypto/suite.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/impl.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    _ = impl;
}
