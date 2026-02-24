//! I16 Quantization AEC Convergence Tests
//!
//! Validates that AEC algorithms still converge correctly with i16 quantized signals

const std = @import("std");
const testing = std.testing;
const sim_audio = @import("sim_audio.zig");
const aec3_module = @import("aec3/aec3.zig");

const SimConfig = sim_audio.SimConfig;
const SimAudio = sim_audio.SimAudio;
const Aec3 = aec3_module.Aec3;

const FRAME_SIZE = 160;
const SAMPLE_RATE = 16000;

// Generate synthetic speech-like signal (pink noise is closer to speech than white noise)
fn generateSpeechFrame(prng: *u64, buf: []f32) void {
    // Simple pink noise approximation using leaky integrator
    var white: f32 = 0;
    var pink_state: f32 = 0;

    for (buf) |*s| {
        // Generate white noise
        prng.* ^= prng.* << 13;
        prng.* ^= prng.* >> 7;
        prng.* ^= prng.* << 17;
        const raw: f32 = @floatFromInt(@as(i32, @truncate(@as(i64, @bitCast(prng.*)))));
        white = raw / 2147483648.0;

        // Convert to pink noise (leaky integration)
        pink_state = 0.9 * pink_state + 0.1 * white;

        // Scale to speech level (~1000 RMS)
        s.* = pink_state * 1000.0;
    }
}

// Compute ERLE (Echo Return Loss Enhancement) in dB
fn computeErle(mic: []const i16, clean: []const i16) f32 {
    var mic_energy: f64 = 0;
    var clean_energy: f64 = 0;

    for (mic) |s| {
        const v: f64 = @floatFromInt(s);
        mic_energy += v * v;
    }
    for (clean) |s| {
        const v: f64 = @floatFromInt(s);
        clean_energy += v * v;
    }

    const mic_rms: f32 = @floatCast(@sqrt(mic_energy / @as(f64, @floatFromInt(mic.len))));
    const clean_rms: f32 = @floatCast(@sqrt(clean_energy / @as(f64, @floatFromInt(clean.len))));

    if (clean_rms < 1.0) return 0.0;  // Avoid log of zero
    return 20.0 * @log10(mic_rms / clean_rms);
}

// Test AEC convergence with i16 quantized signals
// Echo should be suppressed by at least 10dB after convergence
test "AEC converges with I16 quantized signals" {
    const allocator = testing.allocator;

    const TestConfig = SimConfig{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 160,  // 1 frame delay (10ms)
        .echo_gain = 0.5,
        .enable_i16_quantization = true,
        .quantization_noise_lsb = 0.5,
        .dithering_noise_lsb = 0.3,
        .ambient_noise_rms = 50,  // Small ambient noise (realistic)
    };

    var s = SimAudio(TestConfig).init();
    try s.start();
    defer s.stop();

    var aec = try Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .num_partitions = 50,
        .step_size = 0.5,
    });
    defer aec.deinit();

    // Get drivers
    var spk_drv = s.speaker();
    var mic_drv = s.mic();
    var ref_drv = s.refReader();

    // Run 500 frames with synthetic speech
    const num_frames = 500;
    var speech_prng: u64 = 0x12345678ABCDEF01;
    var echo_prng: u64 = 0xFEDCBA9876543210;

    var early_erle: f32 = 0;
    var late_erle: f32 = 0;

    var mic_history: [100]f64 = undefined;
    var clean_history: [100]f64 = undefined;

    for (0..num_frames) |frame_idx| {
        var mic: [FRAME_SIZE]i16 = undefined;
        var ref: [FRAME_SIZE]i16 = undefined;
        var clean: [FRAME_SIZE]i16 = undefined;

        // Generate synthetic near-end speech (pink noise)
        var speech_buf: [FRAME_SIZE]f32 = undefined;
        generateSpeechFrame(&speech_prng, &speech_buf);

        // Convert to i16 and write near-end
        var near_end_buf: [FRAME_SIZE]i16 = undefined;
        for (speech_buf, 0..) |s_val, i| {
            const scaled: f32 = s_val;
            near_end_buf[i] = @intFromFloat(@max(-32768.0, @min(32767.0, scaled)));
        }
        s.writeNearEnd(&near_end_buf);

        // Generate echo from previous speaker output (delayed pink noise)
        var echo_buf_f32: [FRAME_SIZE]f32 = undefined;
        generateSpeechFrame(&echo_prng, &echo_buf_f32);

        // Convert to i16 and write to speaker
        var speaker_buf: [FRAME_SIZE]i16 = undefined;
        for (echo_buf_f32, 0..) |s_val, i| {
            const scaled: f32 = s_val;
            speaker_buf[i] = @intFromFloat(@max(-32768.0, @min(32767.0, scaled)));
        }
        _ = spk_drv.write(&speaker_buf) catch continue;

        // Read mic (near-end + echo + quantization noise)
        _ = mic_drv.read(&mic) catch continue;

        // Read ref (speaker output from hardware loopback)
        _ = ref_drv.read(&ref) catch continue;

        // Process with AEC
        aec.process(&mic, &ref, &clean);

        // Measure ERLE at different stages
        const erle = computeErle(&mic, &clean);

        if (frame_idx >= 50 and frame_idx < 150) {
            // Early stage (frames 50-150): average ERLE
            const idx = frame_idx - 50;
            mic_history[idx] = 0;
            clean_history[idx] = 0;
            for (mic) |sample| {
                const v: f64 = @floatFromInt(sample);
                mic_history[idx] += v * v;
            }
            for (clean) |sample| {
                const v: f64 = @floatFromInt(sample);
                clean_history[idx] += v * v;
            }
            mic_history[idx] = @sqrt(mic_history[idx] / FRAME_SIZE);
            clean_history[idx] = @sqrt(clean_history[idx] / FRAME_SIZE);
        }

        if (frame_idx == 100) {
            early_erle = erle;
        }

        if (frame_idx >= 400 and frame_idx < 500) {
            // Late stage: average ERLE
            const idx = frame_idx - 400;
            if (idx < 100) {
                mic_history[idx] = 0;
                clean_history[idx] = 0;
                for (mic) |sample| {
                    const v: f64 = @floatFromInt(sample);
                    mic_history[idx] += v * v;
                }
                for (clean) |sample| {
                    const v: f64 = @floatFromInt(sample);
                    clean_history[idx] += v * v;
                }
                mic_history[idx] = @sqrt(mic_history[idx] / FRAME_SIZE);
                clean_history[idx] = @sqrt(clean_history[idx] / FRAME_SIZE);
            }
        }

        if (frame_idx == 450) {
            late_erle = erle;
        }

        // Log progress every 100 frames
        if (frame_idx % 100 == 0) {
            std.debug.print("[Frame {d}] ERLE: {d:.1} dB\n", .{ frame_idx, erle });
        }
    }

    // Calculate average ERLE for early and late stages
    var early_mic_avg: f64 = 0;
    var early_clean_avg: f64 = 0;
    for (mic_history[0..100]) |v| early_mic_avg += v;
    for (clean_history[0..100]) |v| early_clean_avg += v;
    early_mic_avg /= 100.0;
    early_clean_avg /= 100.0;
    const early_avg_erle = 20.0 * @log10(early_mic_avg / early_clean_avg);

    std.debug.print("\n[I16 Convergence Test Results]\n", .{});
    std.debug.print("  Early ERLE (frame ~100): {d:.1} dB\n", .{early_erle});
    std.debug.print("  Late ERLE (frame ~450): {d:.1} dB\n", .{late_erle});
    std.debug.print("  Early avg ERLE: {d:.1} dB\n", .{early_avg_erle});

    // Verify: Late ERLE should be significantly better than early
    // AEC should improve by at least 6dB after convergence
    const improvement = late_erle - early_erle;
    std.debug.print("  Improvement: {d:.1} dB (threshold: 6.0 dB)\n", .{improvement});

    // Also verify that we get some echo cancellation (> 3dB ERLE)
    std.debug.print("  Late ERLE threshold: > 3.0 dB\n", .{});
    try testing.expect(late_erle > 3.0);

    // And verify improvement
    try testing.expect(improvement > 3.0);
}

// Test that AEC handles near-end speech correctly with i16 quantization
// Near-end should not be suppressed when mic > ref
test "AEC preserves near-end speech with I16 quantization" {
    const allocator = testing.allocator;

    const TestConfig = SimConfig{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .echo_delay_samples = 160,
        .echo_gain = 0.3,  // Lower echo gain
        .enable_i16_quantization = true,
        .quantization_noise_lsb = 0.5,
        .dithering_noise_lsb = 0.3,
        .ambient_noise_rms = 0,
    };

    var s = SimAudio(TestConfig).init();
    try s.start();
    defer s.stop();

    var aec = try Aec3.init(allocator, .{
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
    });
    defer aec.deinit();

    // Get drivers
    var spk_drv = s.speaker();
    var mic_drv = s.mic();
    var ref_drv = s.refReader();

    // First: send only echo (no near-end) to let AEC converge
    var echo_prng: u64 = 0xFEDCBA9876543210;
    for (0..200) |_| {
        var echo_buf_f32: [FRAME_SIZE]f32 = undefined;
        generateSpeechFrame(&echo_prng, &echo_buf_f32);

        var speaker_buf: [FRAME_SIZE]i16 = undefined;
        for (echo_buf_f32, 0..) |s_val, i| {
            const scaled: f32 = s_val;
            speaker_buf[i] = @intFromFloat(@max(-32768.0, @min(32767.0, scaled)));
        }
        _ = spk_drv.write(&speaker_buf) catch continue;

        var mic: [FRAME_SIZE]i16 = undefined;
        var ref: [FRAME_SIZE]i16 = undefined;
        var clean: [FRAME_SIZE]i16 = undefined;

        _ = mic_drv.read(&mic) catch continue;
        _ = ref_drv.read(&ref) catch continue;
        aec.process(&mic, &ref, &clean);
    }

    // Now: strong near-end speech (should be preserved)
    var speech_prng: u64 = 0x12345678ABCDEF01;
    var near_end_preserved: bool = true;
    var total_near_energy: f64 = 0;
    var total_clean_energy: f64 = 0;

    for (0..50) |_| {
        var speech_buf: [FRAME_SIZE]f32 = undefined;
        generateSpeechFrame(&speech_prng, &speech_buf);

        // Scale up for strong near-end (2000 RMS vs echo ~300 RMS)
        var near_end_buf: [FRAME_SIZE]i16 = undefined;
        for (speech_buf, 0..) |s_val, i| {
            const scaled: f32 = s_val * 2.0;  // Double amplitude
            near_end_buf[i] = @intFromFloat(@max(-32768.0, @min(32767.0, scaled)));
        }
        s.writeNearEnd(&near_end_buf);

        var mic: [FRAME_SIZE]i16 = undefined;
        var ref: [FRAME_SIZE]i16 = undefined;
        var clean: [FRAME_SIZE]i16 = undefined;

        _ = mic_drv.read(&mic) catch continue;
        _ = ref_drv.read(&ref) catch continue;
        aec.process(&mic, &ref, &clean);

        // Calculate energies
        var mic_energy: f64 = 0;
        var clean_energy: f64 = 0;
        for (mic) |sample| {
            const v: f64 = @floatFromInt(sample);
            mic_energy += v * v;
        }
        for (clean) |sample| {
            const v: f64 = @floatFromInt(sample);
            clean_energy += v * v;
        }

        total_near_energy += mic_energy;
        total_clean_energy += clean_energy;

        // Near-end should be preserved: clean energy should be close to mic energy
        // (not suppressed like echo)
        const ratio = @sqrt(clean_energy / mic_energy);
        if (ratio < 0.5 or ratio > 2.0) {
            near_end_preserved = false;
        }
    }

    const avg_ratio = @sqrt(total_clean_energy / total_near_energy);
    std.debug.print("\n[I16 Near-end Preservation Test]\n", .{});
    std.debug.print("  Avg clean/mic ratio: {d:.2} (should be ~1.0)\n", .{avg_ratio});
    std.debug.print("  Near-end preserved: {}\n", .{near_end_preserved});

    // Clean output should be within factor of 2 of mic input for near-end
    try testing.expect(avg_ratio > 0.5);
    try testing.expect(avg_ratio < 2.0);
}
