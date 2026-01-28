const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("trait", .{
        .root_source_file = b.path("src/trait.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests - test trait.zig which imports all interface modules
    const test_step = b.step("test", "Run unit tests");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/trait.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}
