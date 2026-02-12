const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const crypto_dep = b.dependency("crypto", .{
        .target = target,
        .optimize = optimize,
    });
    const kcp_dep = b.dependency("kcp", .{
        .target = target,
        .optimize = optimize,
    });
    const channel_dep = b.dependency("channel", .{
        .target = target,
        .optimize = optimize,
    });

    const noise_mod = b.addModule("noise", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    noise_mod.addImport("trait", trait_dep.module("trait"));
    noise_mod.addImport("crypto", crypto_dep.module("crypto"));
    noise_mod.addImport("kcp", kcp_dep.module("kcp"));
    noise_mod.addImport("async/channel", channel_dep.module("channel"));

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("trait", trait_dep.module("trait"));
    unit_tests.root_module.addImport("crypto", crypto_dep.module("crypto"));
    unit_tests.root_module.addImport("kcp", kcp_dep.module("kcp"));
    unit_tests.root_module.addImport("async/channel", channel_dep.module("channel"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
