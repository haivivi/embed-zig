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

    const steps = [_]struct { name: []const u8, file: []const u8, desc: []const u8 }{
        .{ .name = "mic-check", .file = "mic_check.zig", .desc = "Step 1: Mic recording test" },
        .{ .name = "step2", .file = "step2_speaker_mic.zig", .desc = "Step 2: Speaker + mic record" },
        .{ .name = "step3", .file = "step3_aec3.zig", .desc = "Step 3: 440Hz + AEC3" },
        .{ .name = "step4", .file = "step4_sweep_aec3.zig", .desc = "Step 4: Sweep + AEC3" },
        .{ .name = "step5", .file = "step5_tts_aec3.zig", .desc = "Step 5: TTS + AEC3" },
        .{ .name = "step6", .file = "step6_conversation.zig", .desc = "Step 6: Conversation + AEC3" },
        .{ .name = "loopback", .file = "loopback.zig", .desc = "Raw mic→speaker loopback (no AEC)" },
        .{ .name = "t5-60s", .file = "step_t5_60s.zig", .desc = "T5: 60s stability test" },
        .{ .name = "diag-mic", .file = "diag_mic_only.zig", .desc = "Diagnostic: mic only, quiet room" },
        .{ .name = "diag-offset", .file = "diag_offset.zig", .desc = "Diagnostic: measure mic/ref offset with tone" },
        .{ .name = "diag-analyze", .file = "diag_analyze.zig", .desc = "Analyze loop recordings" },
        .{ .name = "diag", .file = "diag_duplex.zig", .desc = "Diagnostic: DuplexAudio mic vs ref alignment" },
        .{ .name = "diag-aec", .file = "diag_aec_offline.zig", .desc = "Diagnostic: AEC3 offline with real data" },
        .{ .name = "diag-loop", .file = "diag_simple_loop.zig", .desc = "Diagnostic: simplest AEC loop (no engine)" },
        .{ .name = "diag-noise", .file = "diag_noise_source.zig", .desc = "Diagnostic: analyze noise source frame by frame" },
        .{ .name = "diag-align", .file = "diag_ref_alignment.zig", .desc = "Diagnostic: verify ref/mic alignment" },
        .{ .name = "e1", .file = "E1_engine_loopback.zig", .desc = "E1: Engine loopback (DuplexStream + RefReader)" },
        .{ .name = "e1b", .file = "E1b_engine_separate.zig", .desc = "E1b: Engine loopback (separate streams + buffer_depth)" },
        .{ .name = "e2", .file = "E2_engine_tts.zig", .desc = "E2: Engine TTS (DuplexStream)" },
        .{ .name = "e3", .file = "E3_engine_multi_round.zig", .desc = "E3: Multi-round conversation (DuplexStream)" },
        .{ .name = "e4", .file = "E4_engine_60s.zig", .desc = "E4: 60s Engine long-running (DuplexStream)" },
        .{ .name = "e5", .file = "E5_engine_nearend.zig", .desc = "E5: Near-end detection (DuplexStream)" },
        .{ .name = "analyze", .file = "analyze_wav.zig", .desc = "Analyze recorded WAV files" },
        .{ .name = "mic-only", .file = "mic_only_record.zig", .desc = "Simple mic-only recording (no AEC, no speaker)" },
        .{ .name = "mic-spk-no-aec", .file = "mic_spk_no_aec.zig", .desc = "Mic→Speaker passthrough without AEC" },
        .{ .name = "analyze-single", .file = "analyze_single_wav.zig", .desc = "Analyze single WAV file" },
        .{ .name = "quick-analyze", .file = "quick_analyze.zig", .desc = "Quick WAV file analysis with args" },
        .{ .name = "spectrum", .file = "spectrum_analyze.zig", .desc = "FFT spectrum analysis" },
        .{ .name = "silence-duplex", .file = "silence_duplex.zig", .desc = "Test silence playback with mic recording" },
        .{ .name = "low-volume", .file = "low_volume_test.zig", .desc = "Test low volume feedback" },
        .{ .name = "e1-silence", .file = "E1_with_silence_output.zig", .desc = "E1 with silence output (isolate feedback)" },
        .{ .name = "simple", .file = "simple_passthrough.zig", .desc = "Simplest: mic → speaker, NO AEC" },
    };

    // std_impl needs portaudio for audio_engine.zig
    const std_impl_mod = std_impl_dep.module("std_impl");
    std_impl_mod.addImport("portaudio", pa_module);

    // wav_writer module for audio recording
    const wav_module = b.createModule(.{
        .root_source_file = b.path("wav_writer.zig"),
        .target = target,
        .optimize = optimize,
    });

    // wav_reader module for analysis
    const wav_reader_module = b.createModule(.{
        .root_source_file = b.path("wav_reader.zig"),
        .target = target,
        .optimize = optimize,
    });

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
        exe.root_module.addImport("std_impl", std_impl_mod);
        exe.root_module.addImport("wav_writer", wav_module);
        exe.root_module.addImport("wav_reader", wav_reader_module);
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
        // Allow passing command line arguments
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }
        const run_step = b.step(s.name, s.desc);
        run_step.dependOn(&run_cmd.step);
    }
}
