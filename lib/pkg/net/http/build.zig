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
    const dns_dep = b.dependency("net/dns", .{
        .target = target,
        .optimize = optimize,
    });
    const std_impl_dep = b.dependency("std_impl", .{
        .target = target,
        .optimize = optimize,
    });

    // Create the http module
    const http_mod = b.addModule("net/http", .{
        .root_source_file = b.path("src/http.zig"),
        .target = target,
        .optimize = optimize,
    });
    http_mod.addImport("trait", trait_dep.module("trait"));
    http_mod.addImport("net/tls", tls_dep.module("net/tls"));
    http_mod.addImport("net/dns", dns_dep.module("net/dns"));

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/http.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    tests.root_module.addImport("net/tls", tls_dep.module("net/tls"));
    tests.root_module.addImport("net/dns", dns_dep.module("net/dns"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    // Integration test (run-test)
    const run_test_step = b.step("run-test", "Run integration tests with real network");
    const integration_test = b.addExecutable(.{
        .name = "http_integration_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test_http.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_test.root_module.addImport("src/http.zig", http_mod);
    integration_test.root_module.addImport("std_impl", std_impl_dep.module("std_impl"));
    integration_test.root_module.addImport("trait", trait_dep.module("trait"));
    integration_test.root_module.addImport("net/tls", tls_dep.module("net/tls"));
    integration_test.root_module.addImport("net/dns", dns_dep.module("net/dns"));
    const run_integration = b.addRunArtifact(integration_test);
    run_test_step.dependOn(&run_integration.step);
}
