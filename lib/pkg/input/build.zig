const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Module
    _ = b.addModule("input", .{
        .root_source_file = b.path("src/adc_button.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Tests
    const test_step = b.step("test", "Run input tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/adc_button.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
