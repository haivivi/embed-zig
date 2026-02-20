const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = "../../../";

    const trait_dep = b.dependency("trait", .{ .target = target, .optimize = optimize });
    const speexdsp_dep = b.dependency("speexdsp", .{ .target = target, .optimize = optimize });
    const std_impl_dep = b.dependency("std_impl", .{ .target = target, .optimize = optimize });

    const pa_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = root ++ "lib/pkg/portaudio/src/portaudio.zig" },
        .target = target,
        .optimize = optimize,
    });
    pa_module.addIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    pa_module.link_libc = true;

    const audio_module = b.createModule(.{
        .root_source_file = .{ .cwd_relative = root ++ "lib/pkg/audio/src/audio.zig" },
        .target = target,
        .optimize = optimize,
    });
    audio_module.addImport("trait", trait_dep.module("trait"));
    audio_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));

    const exe = b.addExecutable(.{
        .name = "audio_engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("portaudio", pa_module);
    exe.root_module.addImport("audio", audio_module);
    exe.root_module.addImport("std_impl", std_impl_dep.module("std_impl"));
    exe.root_module.link_libc = true;

    // Link PortAudio
    exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.linkSystemLibrary("portaudio");
    exe.linkFramework("CoreAudio");
    exe.linkFramework("AudioToolbox");
    exe.linkFramework("AudioUnit");
    exe.linkFramework("CoreFoundation");
    exe.linkFramework("CoreServices");

    // Link pre-built SpeexDSP from Bazel
    exe.addObjectFile(.{
        .cwd_relative = root ++ "bazel-bin/third_party/speexdsp/libspeexdsp_float.a",
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run AEC engine with real mic + speaker");
    run_step.dependOn(&run_cmd.step);
}
