const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const math_dep = b.dependency("math", .{
        .target = target,
        .optimize = optimize,
    });

    const imu_mod = b.addModule("imu", .{
        .root_source_file = b.path("src/imu.zig"),
        .target = target,
        .optimize = optimize,
    });
    imu_mod.addImport("trait", trait_dep.module("trait"));
    imu_mod.addImport("math", math_dep.module("math"));

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/imu.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("trait", trait_dep.module("trait"));
    unit_tests.root_module.addImport("math", math_dep.module("math"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
