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

    // Zig client for cross-testing
    const zig_client = b.addExecutable(.{
        .name = "zig_mqtt_client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/zig_client.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zig_client.root_module.addImport("mqtt0", mqtt0_mod);
    const run_client = b.addRunArtifact(zig_client);
    if (b.args) |a| run_client.addArgs(a);
    const run_client_step = b.step("run-client", "Run Zig MQTT client");
    run_client_step.dependOn(&run_client.step);

    // Zig broker for cross-testing
    const zig_broker = b.addExecutable(.{
        .name = "zig_mqtt_broker",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/zig_broker.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    zig_broker.root_module.addImport("mqtt0", mqtt0_mod);
    const run_broker = b.addRunArtifact(zig_broker);
    if (b.args) |a| run_broker.addArgs(a);
    const run_broker_step = b.step("run-broker", "Run Zig MQTT broker");
    run_broker_step.dependOn(&run_broker.step);
}
