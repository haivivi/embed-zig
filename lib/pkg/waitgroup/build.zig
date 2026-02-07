const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const std_sal_dep = b.dependency("std_sal", .{
        .target = target,
        .optimize = optimize,
    });

    // Module (only depends on trait)
    const waitgroup_mod = b.addModule("waitgroup", .{
        .root_source_file = b.path("src/waitgroup.zig"),
        .target = target,
        .optimize = optimize,
    });
    waitgroup_mod.addImport("trait", trait_dep.module("trait"));

    // Unit tests (also needs runtime for test Runtime type)
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/waitgroup.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    tests.root_module.addImport("runtime", b.createModule(.{
        .root_source_file = std_sal_dep.path("src/impl/runtime.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
