const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Dependencies
    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const nfc_dep = b.dependency("nfc", .{
        .target = target,
        .optimize = optimize,
    });

    // FM175XX driver module
    const fm175xx_mod = b.addModule("fm175xx", .{
        .root_source_file = b.path("src/fm175xx.zig"),
        .target = target,
        .optimize = optimize,
    });
    fm175xx_mod.addImport("trait", trait_dep.module("trait"));
    fm175xx_mod.addImport("nfc", nfc_dep.module("nfc"));

    // Unit tests
    const test_step = b.step("test", "Run unit tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/fm175xx.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("trait", trait_dep.module("trait"));
    test_mod.addImport("nfc", nfc_dep.module("nfc"));

    const tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
