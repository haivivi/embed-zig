const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    // mqtt0 module
    const mqtt0_mod = b.addModule("mqtt0", .{
        .root_source_file = b.path("src/mqtt0.zig"),
        .target = target,
        .optimize = optimize,
    });
    mqtt0_mod.addImport("trait", trait_dep.module("trait"));

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mqtt0.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Integration test executable
    const std_sal_dep = b.dependency("std_sal", .{
        .target = target,
        .optimize = optimize,
    });

    const integration_test = b.addExecutable(.{
        .name = "mqtt0_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_mqtt0.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_test.root_module.addImport("mqtt0", mqtt0_mod);
    integration_test.root_module.addImport("trait", trait_dep.module("trait"));
    integration_test.root_module.addImport("std_sal", std_sal_dep.module("std_sal"));

    const run_integration = b.addRunArtifact(integration_test);
    const run_step = b.step("run-test", "Run integration test");
    run_step.dependOn(&run_integration.step);
}
