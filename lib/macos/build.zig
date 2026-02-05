const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get impl module from dependency
    const impl_dep = b.dependency("impl", .{
        .target = target,
        .optimize = optimize,
    });

    // Get darwin module from dependency
    const darwin_dep = b.dependency("darwin", .{
        .target = target,
        .optimize = optimize,
    });

    // Main macos module
    const macos = b.addModule("macos", .{
        .root_source_file = b.path("src/macos.zig"),
        .target = target,
        .optimize = optimize,
    });
    macos.addImport("impl", impl_dep.module("impl"));
    macos.addImport("darwin", darwin_dep.module("darwin"));

    // Tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macos.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("impl", impl_dep.module("impl"));
    tests.root_module.addImport("darwin", darwin_dep.module("darwin"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
