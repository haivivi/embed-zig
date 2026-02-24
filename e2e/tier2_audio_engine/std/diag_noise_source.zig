//! Diagnostic: Analyze noise source frame by frame
//!
//! Test 1: Silent room, no playback → measure baseline mic noise
//! Test 2: Silent room, with feedback loop (mic → speaker) → measure feedback noise
//!
//! Compare to identify noise source.

const std = @import("std");
const pa = @import("portaudio");
const wav = @import("wav_writer");

const std_impl = @import("std_impl");
const da = std_impl.audio_engine;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const DURATION_S: u32 = 5;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    std.debug.print("\n=== Noise Source Diagnostic ===\n", .{});
    std.debug.print("Test 1: Mic only (no speaker output)\n", .{});
    std.debug.print("Test 2: Mic → Speaker feedback loop\n\n", .{});

    try pa.init();
    defer pa.deinit();

    if (pa.deviceInfo(pa.defaultInputDevice())) |info| std.debug.print("Input:  {s}\n", .{info.name});
    if (pa.deviceInfo(pa.defaultOutputDevice())) |info| std.debug.print("Output: {s}\n\n", .{info.name});

    // ========== Test 1: Mic only (speaker outputs silence) ==========
    std.debug.print("=== Test 1: Mic only (speaker silent) ===\n", .{});

    var duplex1 = try da.DuplexAudio.init(allocator);
    var mic1 = duplex1.mic();
    var spk1 = duplex1.speaker();
    var ref1 = duplex1.refReader();


    std.Thread.sleep(100 * std.time.ns_per_ms);
    const offset1 = duplex1.getRefOffset();
    std.debug.print("Hardware offset: {d} samples ({d:.1}ms)\n\n", .{ offset1, @as(f64, @floatFromInt(offset1)) / 16.0 });

    var mic1_wav = try wav.WavWriter.init("diag_noise_mic1.wav", SAMPLE_RATE);
    var ref1_wav = try wav.WavWriter.init("diag_noise_ref1.wav", SAMPLE_RATE);

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var silent_buf: [FRAME_SIZE]i16 = [_]i16{0} ** FRAME_SIZE;

    var frame_count: usize = 0;
    const deadline1 = std.time.milliTimestamp() + DURATION_S * 1000;

    std.debug.print("Recording... (speaker outputs silence)\n", .{});

    while (std.time.milliTimestamp() < deadline1) {
        _ = mic1.read(&mic_buf) catch continue;
        _ = ref1.read(&ref_buf) catch continue;

        // Output silence to speaker
        _ = spk1.write(&silent_buf) catch continue;

        try mic1_wav.writeSamples(&mic_buf);
        try ref1_wav.writeSamples(&ref_buf);

        frame_count += 1;
        if (frame_count % 50 == 0) {
            var mic_e: f64 = 0;
            var ref_e: f64 = 0;
            var mic_max: i16 = 0;
            for (0..FRAME_SIZE) |i| {
                const mv: f64 = @floatFromInt(mic_buf[i]);
                const rv: f64 = @floatFromInt(ref_buf[i]);
                mic_e += mv * mv;
                ref_e += rv * rv;
                if (@abs(mic_buf[i]) > @abs(mic_max)) mic_max = mic_buf[i];
            }
            const mr = @sqrt(mic_e / FRAME_SIZE);
            const rr = @sqrt(ref_e / FRAME_SIZE);
            std.debug.print("[{d:.1}s] mic_rms={d:>6.0} mic_max={d:>6} ref_rms={d:>6.0}\n", .{
                @as(f64, @floatFromInt(frame_count)) / 100.0, mr, mic_max, rr,
            });
        }
    }

    duplex1.stop();
    try mic1_wav.close();
    try ref1_wav.close();

    std.debug.print("\nTest 1 done. {d} frames recorded.\n\n", .{frame_count});

    // ========== Test 2: Feedback loop (mic → speaker) ==========
    std.debug.print("=== Test 2: Mic → Speaker feedback loop ===\n", .{});
    std.debug.print("WARNING: This may produce loud noise! Keep volume low.\n", .{});

    var duplex2 = try da.DuplexAudio.init(allocator);
    var mic2 = duplex2.mic();
    var spk2 = duplex2.speaker();
    var ref2 = duplex2.refReader();

    std.Thread.sleep(100 * std.time.ns_per_ms);

    var mic2_wav = try wav.WavWriter.init("diag_noise_mic2.wav", SAMPLE_RATE);
    var ref2_wav = try wav.WavWriter.init("diag_noise_ref2.wav", SAMPLE_RATE);
    var spk2_wav = try wav.WavWriter.init("diag_noise_spk2.wav", SAMPLE_RATE);

    frame_count = 0;
    const deadline2 = std.time.milliTimestamp() + DURATION_S * 1000;

    std.debug.print("Recording... (mic → speaker, NO AEC)\n", .{});
    std.debug.print("Watch for RMS growth indicating feedback!\n\n", .{});

    var prev_mic_rms: f64 = 0;

    while (std.time.milliTimestamp() < deadline2) {
        _ = mic2.read(&mic_buf) catch continue;
        _ = ref2.read(&ref_buf) catch continue;

        // FEEDBACK: mic → speaker (no AEC!)
        // Apply gain reduction to prevent extreme feedback
        var gain_buf: [FRAME_SIZE]i16 = undefined;
        for (0..FRAME_SIZE) |i| {
            // 50% volume to slow down feedback buildup
            gain_buf[i] = @intFromFloat(@as(f32, @floatFromInt(mic_buf[i])) * 0.5);
        }
        _ = spk2.write(&gain_buf) catch continue;

        try mic2_wav.writeSamples(&mic_buf);
        try ref2_wav.writeSamples(&ref_buf);
        try spk2_wav.writeSamples(&gain_buf);

        frame_count += 1;
        if (frame_count % 50 == 0) {
            var mic_e: f64 = 0;
            var ref_e: f64 = 0;
            var spk_e: f64 = 0;
            var mic_max: i16 = 0;
            for (0..FRAME_SIZE) |i| {
                const mv: f64 = @floatFromInt(mic_buf[i]);
                const rv: f64 = @floatFromInt(ref_buf[i]);
                const sv: f64 = @floatFromInt(gain_buf[i]);
                mic_e += mv * mv;
                ref_e += rv * rv;
                spk_e += sv * sv;
                if (@abs(mic_buf[i]) > @abs(mic_max)) mic_max = mic_buf[i];
            }
            const mr = @sqrt(mic_e / FRAME_SIZE);
            const rr = @sqrt(ref_e / FRAME_SIZE);
            const sr = @sqrt(spk_e / FRAME_SIZE);
            const growth = if (prev_mic_rms > 100) mr / prev_mic_rms else 1.0;
            prev_mic_rms = mr;

            const warning = if (growth > 1.1) " ⚠️ FEEDBACK!" else "";
            std.debug.print("[{d:.1}s] mic_rms={d:>6.0} mic_max={d:>6} ref_rms={d:>6.0} spk_rms={d:>6.0} growth={d:.2}{s}\n", .{
                @as(f64, @floatFromInt(frame_count)) / 100.0, mr, mic_max, rr, sr, growth, warning,
            });
        }
    }

    duplex2.stop();
    try mic2_wav.close();
    try ref2_wav.close();
    try spk2_wav.close();

    std.debug.print("\nTest 2 done. {d} frames recorded.\n\n", .{frame_count});

    // ========== Analysis ==========
    std.debug.print("=== Analysis ===\n", .{});
    std.debug.print("Compare the two WAV file sets:\n", .{});
    std.debug.print("  diag_noise_mic1.wav - mic with speaker silent (baseline noise)\n", .{});
    std.debug.print("  diag_noise_mic2.wav - mic with feedback loop\n", .{});
    std.debug.print("  diag_noise_ref1.wav - ref with speaker silent (should be ~0)\n", .{});
    std.debug.print("  diag_noise_ref2.wav - ref with feedback loop\n", .{});
    std.debug.print("  diag_noise_spk2.wav - what was sent to speaker\n\n", .{});

    std.debug.print("If Test 1 mic_rms is high → noise from environment/mic hardware\n", .{});
    std.debug.print("If Test 2 shows growing RMS → feedback loop is active\n", .{});
    std.debug.print("If Test 1 mic_rms is low but Test 2 grows → feedback amplification\n\n", .{});
}
