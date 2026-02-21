const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const root = "../../../";

    const trait_dep = b.dependency("trait", .{ .target = target, .optimize = optimize });
    const speexdsp_dep = b.dependency("speexdsp", .{ .target = target, .optimize = optimize });

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

    const steps = [_]struct { name: []const u8, file: []const u8, desc: []const u8 }{
        .{ .name = "mic-check", .file = "mic_check.zig", .desc = "Step 1: Mic recording test" },
        .{ .name = "step2", .file = "step2_speaker_mic.zig", .desc = "Step 2: Speaker + mic record" },
        .{ .name = "step3", .file = "step3_aec3.zig", .desc = "Step 3: 440Hz + AEC3" },
        .{ .name = "step4", .file = "step4_sweep_aec3.zig", .desc = "Step 4: Sweep + AEC3" },
        .{ .name = "step5", .file = "step5_tts_aec3.zig", .desc = "Step 5: TTS + AEC3" },
        .{ .name = "step6", .file = "step6_conversation.zig", .desc = "Step 6: Conversation + AEC3" },
        .{ .name = "loopback", .file = "loopback.zig", .desc = "Raw mic→speaker loopback (no AEC)" },
    };

    for (steps) |s| {
        const exe = b.addExecutable(.{
            .name = s.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(s.file),
                .target = target,
                .optimize = optimize,
            }),
        });
        exe.root_module.addImport("portaudio", pa_module);
        exe.root_module.addImport("audio", audio_module);
        exe.root_module.link_libc = true;
        exe.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
        exe.linkSystemLibrary("portaudio");
        exe.linkFramework("CoreAudio");
        exe.linkFramework("AudioToolbox");
        exe.linkFramework("AudioUnit");
        exe.linkFramework("CoreFoundation");
        exe.linkFramework("CoreServices");
        exe.addObjectFile(.{
            .cwd_relative = root ++ "bazel-bin/third_party/speexdsp/libspeexdsp_float.a",
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step(s.name, s.desc);
        run_step.dependOn(&run_cmd.step);
    }
}
