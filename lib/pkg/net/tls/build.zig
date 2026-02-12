const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Get dependencies
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const crypto_dep = b.dependency("crypto", .{
        .target = target,
        .optimize = optimize,
    });

    const tls_mod = b.addModule("net/tls", .{
        .root_source_file = b.path("src/tls.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_mod.addImport("trait", trait_dep.module("trait"));
    tls_mod.addImport("crypto", crypto_dep.module("crypto"));

    // Tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tls.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    tests.root_module.addImport("crypto", crypto_dep.module("crypto"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
