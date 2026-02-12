const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    const kcp_mod = b.addModule("kcp", .{
        .root_source_file = b.path("src/mod.zig"),
        .target = target,
        .optimize = optimize,
    });
    kcp_mod.addImport("trait", trait_dep.module("trait"));

    // Add C library
    kcp_mod.addCSourceFile(.{
        .file = b.path("src/ikcp.c"),
        .flags = &.{ "-O3", "-DNDEBUG", "-fno-sanitize=undefined" },
    });
    kcp_mod.addIncludePath(b.path("src"));
    kcp_mod.link_libc = true;

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mod.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addImport("trait", trait_dep.module("trait"));
    unit_tests.root_module.addCSourceFile(.{
        .file = b.path("src/ikcp.c"),
        .flags = &.{ "-O3", "-DNDEBUG", "-fno-sanitize=undefined" },
    });
    unit_tests.root_module.addIncludePath(b.path("src"));
    unit_tests.root_module.link_libc = true;

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
