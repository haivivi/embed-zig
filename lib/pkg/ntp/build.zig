const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    const ntp_mod = b.addModule("ntp", .{
        .root_source_file = b.path("src/ntp.zig"),
        .target = target,
        .optimize = optimize,
    });
    ntp_mod.addImport("trait", trait_dep.module("trait"));

    // Unit Tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ntp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // std_sal dependency (for host socket)
    const std_sal_dep = b.dependency("std_sal", .{
        .target = target,
        .optimize = optimize,
    });

    // Integration Test - run actual NTP queries
    const integration_test = b.addExecutable(.{
        .name = "ntp_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_ntp.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_test.root_module.addImport("trait", trait_dep.module("trait"));
    integration_test.root_module.addImport("std_sal", std_sal_dep.module("std_sal"));

    const run_integration = b.addRunArtifact(integration_test);
    const run_step = b.step("run-test", "Run NTP integration test");
    run_step.dependOn(&run_integration.step);
}
