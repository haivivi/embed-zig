const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // kcp module
    const kcp_mod = b.addModule("kcp", .{
        .root_source_file = b.path("src/kcp.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kcp.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    // Add ikcp.c (user must have KCP source available)
    // For Bazel builds, the @kcp external repo provides this.
    // For standalone builds, set KCP_PATH env or use default.
    tests.root_module.addCSourceFile(.{
        .file = .{ .cwd_relative = "third_party/kcp/ikcp.c" },
        .flags = &.{"-O3"},
    });
    tests.root_module.addIncludePath(.{ .cwd_relative = "third_party/kcp" });

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);

    _ = kcp_mod;
}
