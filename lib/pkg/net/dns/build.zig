const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const tls_dep = b.dependency("net/tls", .{
        .target = target,
        .optimize = optimize,
    });

    const dns_mod = b.addModule("net/dns", .{
        .root_source_file = b.path("src/dns.zig"),
        .target = target,
        .optimize = optimize,
    });
    dns_mod.addImport("trait", trait_dep.module("trait"));
    dns_mod.addImport("net/tls", tls_dep.module("net/tls"));

    // Unit Tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/dns.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    tests.root_module.addImport("net/tls", tls_dep.module("net/tls"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // std_impl dependency (for host socket)
    const std_impl_dep = b.dependency("std_impl", .{
        .target = target,
        .optimize = optimize,
    });

    // Integration Test - run actual DNS queries
    const integration_test = b.addExecutable(.{
        .name = "dns_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_dns.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_test.root_module.addImport("trait", trait_dep.module("trait"));
    integration_test.root_module.addImport("net/tls", tls_dep.module("net/tls"));
    integration_test.root_module.addImport("std_impl", std_impl_dep.module("std_impl"));

    const run_integration = b.addRunArtifact(integration_test);
    const run_step = b.step("run-test", "Run DNS integration test");
    run_step.dependOn(&run_integration.step);
}
