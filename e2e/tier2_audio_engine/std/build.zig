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

    // step4: sweep AEC
    const step4 = b.addExecutable(.{
        .name = "step4_sweep_aec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("step4_sweep_aec.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    step4.root_module.addImport("portaudio", pa_module);
    step4.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
    step4.root_module.link_libc = true;
    step4.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    step4.linkSystemLibrary("portaudio");
    step4.linkFramework("CoreAudio");
    step4.linkFramework("AudioToolbox");
    step4.linkFramework("AudioUnit");
    step4.linkFramework("CoreFoundation");
    step4.linkFramework("CoreServices");
    step4.addObjectFile(.{ .cwd_relative = root ++ "bazel-bin/third_party/speexdsp/libspeexdsp_float.a" });
    b.installArtifact(step4);
    const step4_run = b.addRunArtifact(step4);
    const step4_step = b.step("step4", "Step 4: Sweep + AEC, no feedback");
    step4_step.dependOn(&step4_run.step);

    // step5: TTS AEC
    const step5 = b.addExecutable(.{
        .name = "step5_tts_aec",
        .root_module = b.createModule(.{
            .root_source_file = b.path("step5_tts_aec.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    step5.root_module.addImport("portaudio", pa_module);
    step5.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
    step5.root_module.link_libc = true;
    step5.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    step5.linkSystemLibrary("portaudio");
    step5.linkFramework("CoreAudio");
    step5.linkFramework("AudioToolbox");
    step5.linkFramework("AudioUnit");
    step5.linkFramework("CoreFoundation");
    step5.linkFramework("CoreServices");
    step5.addObjectFile(.{ .cwd_relative = root ++ "bazel-bin/third_party/speexdsp/libspeexdsp_float.a" });
    b.installArtifact(step5);
    const step5_run = b.addRunArtifact(step5);
    const step5_step = b.step("step5", "Step 5: TTS speech + AEC, no feedback");
    step5_step.dependOn(&step5_run.step);

    // step6: conversation
    const step6 = b.addExecutable(.{
        .name = "step6_conversation",
        .root_module = b.createModule(.{
            .root_source_file = b.path("step6_conversation.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    step6.root_module.addImport("portaudio", pa_module);
    step6.root_module.addImport("speexdsp", speexdsp_dep.module("speexdsp"));
    step6.root_module.link_libc = true;
    step6.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    step6.linkSystemLibrary("portaudio");
    step6.linkFramework("CoreAudio");
    step6.linkFramework("AudioToolbox");
    step6.linkFramework("AudioUnit");
    step6.linkFramework("CoreFoundation");
    step6.linkFramework("CoreServices");
    step6.addObjectFile(.{ .cwd_relative = root ++ "bazel-bin/third_party/speexdsp/libspeexdsp_float.a" });
    b.installArtifact(step6);
    const step6_run = b.addRunArtifact(step6);
    const step6_step = b.step("step6", "Step 6: Real-time conversation — TTS + voice + AEC");
    step6_step.dependOn(&step6_run.step);
}
