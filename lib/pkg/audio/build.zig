const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const trait_dep = b.dependency("trait", .{
        .target = target,
        .optimize = optimize,
    });
    const speexdsp_dep = b.dependency("speexdsp", .{
        .target = target,
        .optimize = optimize,
    });
    const std_impl_dep = b.dependency("std_impl", .{
        .target = target,
        .optimize = optimize,
    });

    // Module
    const audio_module = b.addModule("audio", .{
        .root_source_file = b.path("src/audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    audio_module.addImport("trait", trait_dep.module("trait"));
    audio_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));

    // Tests: resampler
    const resampler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/resampler.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    resampler_tests.root_module.addImport("trait", trait_dep.module("trait"));
    resampler_tests.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
    resampler_tests.root_module.addImport("std_impl", std_impl_dep.module("std_impl"));
    resampler_tests.root_module.addImport("runtime", b.createModule(.{
        .root_source_file = std_impl_dep.path("src/impl/runtime.zig"),
        .target = target,
        .optimize = optimize,
    }));

    // Tests: mixer
    const mixer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mixer.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mixer_tests.root_module.addImport("trait", trait_dep.module("trait"));
    mixer_tests.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
    mixer_tests.root_module.addImport("runtime", b.createModule(.{
        .root_source_file = std_impl_dep.path("src/impl/runtime.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(resampler_tests).step);
    test_step.dependOn(&b.addRunArtifact(mixer_tests).step);
}
