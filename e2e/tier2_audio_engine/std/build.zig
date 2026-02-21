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
    exe.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
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

    // mic_check tool
    const mic_check = b.addExecutable(.{
        .name = "mic_check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("mic_check.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    mic_check.root_module.addImport("portaudio", pa_module);
    mic_check.root_module.link_libc = true;
    mic_check.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mic_check.linkSystemLibrary("portaudio");
    mic_check.linkFramework("CoreAudio");
    mic_check.linkFramework("AudioToolbox");
    mic_check.linkFramework("AudioUnit");
    mic_check.linkFramework("CoreFoundation");
    mic_check.linkFramework("CoreServices");

    b.installArtifact(mic_check);
    const mic_check_run = b.addRunArtifact(mic_check);
    const mic_check_step = b.step("mic-check", "Step 1: Test mic recording at 16kHz and 48kHz");
    mic_check_step.dependOn(&mic_check_run.step);

    // step2: speaker + mic
    const step2 = b.addExecutable(.{
        .name = "step2_speaker_mic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("step2_speaker_mic.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    step2.root_module.addImport("portaudio", pa_module);
    step2.root_module.link_libc = true;
    step2.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    step2.linkSystemLibrary("portaudio");
    step2.linkFramework("CoreAudio");
    step2.linkFramework("AudioToolbox");
    step2.linkFramework("AudioUnit");
    step2.linkFramework("CoreFoundation");
    step2.linkFramework("CoreServices");
    b.installArtifact(step2);
    const step2_run = b.addRunArtifact(step2);
    const step2_step = b.step("step2", "Step 2: Speaker 440Hz + mic record");
    step2_step.dependOn(&step2_run.step);

    // step3: AEC
    const step3 = b.addExecutable(.{
        .name = "step3_aec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("step3_aec.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    step3.root_module.addImport("portaudio", pa_module);
    step3.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
    step3.root_module.link_libc = true;
    step3.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    step3.linkSystemLibrary("portaudio");
    step3.linkFramework("CoreAudio");
    step3.linkFramework("AudioToolbox");
    step3.linkFramework("AudioUnit");
    step3.linkFramework("CoreFoundation");
    step3.linkFramework("CoreServices");
    step3.addObjectFile(.{ .cwd_relative = root ++ "bazel-bin/third_party/speexdsp/libspeexdsp_float.a" });
    b.installArtifact(step3);
    const step3_run = b.addRunArtifact(step3);
    const step3_step = b.step("step3", "Step 3: AEC — 440Hz + mic + AEC, no feedback");
    step3_step.dependOn(&step3_run.step);
}
