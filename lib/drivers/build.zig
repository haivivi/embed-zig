const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get trait dependency
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    const drivers_mod = b.addModule("drivers", .{
        .root_source_file = b.path("src/drivers.zig"),
        .target = target,
        .optimize = optimize,
    });
    drivers_mod.addImport("trait", trait_dep.module("trait"));

    // Unit tests
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/drivers.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("trait", trait_dep.module("trait"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
