const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Audio module
    const audio_module = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Unit tests
    const audio_tests = b.addTest(.{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_tests = b.addRunArtifact(audio_tests);
    const test_step = b.step("test", "Run audio library tests");
    test_step.dependOn(&run_tests.step);

    // Allow using this module from other build.zig files
    _ = audio_module;
}
