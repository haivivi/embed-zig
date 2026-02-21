const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });

    const ws_mod = b.addModule("net/ws", .{
        .root_source_file = b.path("src/ws.zig"),
        .target = target,
        .optimize = optimize,
    });
    ws_mod.addImport("trait", trait_dep.module("trait"));

    const test_step = b.step("test", "Run unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ws.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("trait", trait_dep.module("trait"));
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
