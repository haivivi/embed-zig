//! WAV file analyzer for AEC debugging
const std = @import("std");
const wav = @import("wav_reader.zig");

const SAMPLE_RATE = 16000;
const FRAME_SIZE = 160;
const DURATION_S = 10;

pub fn main() !void {
    // Read all three WAV files
    var mic_wav = try wav.WavReader.init("e1_mic.wav");
    var ref_wav = try wav.WavReader.init("e1_ref.wav");
    var clean_wav = try wav.WavReader.init("e1_clean.wav");

    std.debug.print("\n=== AEC Audio Analysis ===\n", .{});
    std.debug.print("Files: mic={d} samples, ref={d} samples, clean={d} samples\n\n",
        .{mic_wav.num_samples, ref_wav.num_samples, clean_wav.num_samples});

    var frame_count: usize = 0;
    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = undefined;
    var clean_buf: [FRAME_SIZE]i16 = undefined;

    // Statistics
    var ne_frames: usize = 0;  // Near-end detected
    var echo_frames: usize = 0;  // Echo-only frames
    var ne_detected_frames: usize = 0;

    std.debug.print("Frame-by-frame analysis (first 50 frames):\n", .{});
    std.debug.print("{s:>5} {s:>8} {s:>8} {s:>8} {s:>8} {s:>8} {s:>6} {s}\n",
        .{"frame", "mic_rms", "ref_rms", "clean_rms", "ratio", "erle", "ne?", "status"});
    std.debug.print("{s}\n", .{"-" ** 70});

    while (frame_count < 50) {
        const n_mic = try mic_wav.readSamples(&mic_buf);
        const n_ref = try ref_wav.readSamples(&ref_buf);
        const n_clean = try clean_wav.readSamples(&clean_buf);

        if (n_mic < FRAME_SIZE or n_ref < FRAME_SIZE or n_clean < FRAME_SIZE) break;

        // Calculate RMS for each signal
        var mic_e: f64 = 0;
        var ref_e: f64 = 0;
        var clean_e: f64 = 0;
        var mic_max: i16 = 0;
        var ref_max: i16 = 0;

        for (0..FRAME_SIZE) |i| {
            const mv: f64 = @floatFromInt(mic_buf[i]);
            const rv: f64 = @floatFromInt(ref_buf[i]);
            const cv: f64 = @floatFromInt(clean_buf[i]);
            mic_e += mv * mv;
            ref_e += rv * rv;
            clean_e += cv * cv;

            if (@abs(mic_buf[i]) > mic_max) mic_max = @intCast(@abs(mic_buf[i]));
            if (@abs(ref_buf[i]) > ref_max) ref_max = @intCast(@abs(ref_buf[i]));
        }

        const mic_rms = @sqrt(mic_e / FRAME_SIZE);
        const ref_rms = @sqrt(ref_e / FRAME_SIZE);
        const clean_rms = @sqrt(clean_e / FRAME_SIZE);

        // Determine frame type
        const near_end_detected = mic_rms > ref_rms * 1.5;
        const has_ref = ref_rms > 500;
        const has_mic = mic_rms > 100;

        const status = if (near_end_detected)
            "NEAR-END"
        else if (has_ref and mic_rms > ref_rms * 0.5)
            "MIXED"
        else if (has_ref)
            "ECHO"
        else if (has_mic)
            "NOISE"
        else
            "SILENCE";

        // Calculate ERLE (Echo Return Loss Enhancement)
        const erle = if (ref_rms > 100 and clean_rms < ref_rms)
            ref_rms / clean_rms
        else
            0;

        const ne_str = if (near_end_detected) "YES" else "no";

        if (frame_count < 50) {
            std.debug.print("{d:>5} {d:>8.0} {d:>8.0} {d:>8.0} {d:>8.2} {d:>8.1} {s:>6} {s}\n", .{
                frame_count, mic_rms, ref_rms, clean_rms,
                if (ref_rms > 0) mic_rms / ref_rms else 0,
                erle, ne_str, status,
            });
        }

        if (near_end_detected) ne_detected_frames += 1;
        if (has_ref and mic_rms > ref_rms * 0.5) echo_frames += 1;
        if (has_ref and mic_rms > ref_rms * 1.5) ne_frames += 1;

        frame_count += 1;
    }

    // Summary
    std.debug.print("\n=== Summary ===\n", .{});
    std.debug.print("Total frames analyzed: {d}\n", .{frame_count});
    std.debug.print("Near-end detected frames: {d} ({d:.1}%)\n",
        .{ne_detected_frames, @as(f64, @floatFromInt(ne_detected_frames)) / @as(f64, @floatFromInt(frame_count)) * 100});
    std.debug.print("Echo+Near mixed frames: {d}\n", .{ne_frames});

    // Check for issues
    std.debug.print("\n=== Issues Found ===\n", .{});

    // Rewind for detailed analysis
    mic_wav.deinit();
    ref_wav.deinit();
    clean_wav.deinit();
    mic_wav = try wav.WavReader.init("e1_mic.wav");
    ref_wav = try wav.WavReader.init("e1_ref.wav");
    clean_wav = try wav.WavReader.init("e1_clean.wav");

    var suppression_count: usize = 0;
    var over_suppression: usize = 0;

    frame_count = 0;
    while (true) {
        const n_mic = try mic_wav.readSamples(&mic_buf);
        const n_ref = try ref_wav.readSamples(&ref_buf);
        const n_clean = try clean_wav.readSamples(&clean_buf);

        if (n_mic < FRAME_SIZE or n_ref < FRAME_SIZE or n_clean < FRAME_SIZE) break;

        var mic_e: f64 = 0;
        var ref_e: f64 = 0;
        var clean_e: f64 = 0;

        for (0..FRAME_SIZE) |i| {
            mic_e += @as(f64, @floatFromInt(mic_buf[i])) * @as(f64, @floatFromInt(mic_buf[i]));
            ref_e += @as(f64, @floatFromInt(ref_buf[i])) * @as(f64, @floatFromInt(ref_buf[i]));
            clean_e += @as(f64, @floatFromInt(clean_buf[i])) * @as(f64, @floatFromInt(clean_buf[i]));
        }

        const mic_rms = @sqrt(mic_e / FRAME_SIZE);
        const ref_rms = @sqrt(ref_e / FRAME_SIZE);
        const clean_rms = @sqrt(clean_e / FRAME_SIZE);

        // Over-suppression: near-end detected but clean is much lower than mic
        if (mic_rms > ref_rms * 1.5 and mic_rms > 500 and clean_rms < mic_rms * 0.5) {
            suppression_count += 1;
            if (clean_rms < mic_rms * 0.2) {
                over_suppression += 1;
                if (over_suppression <= 5) {
                    std.debug.print("  Frame {d}: mic={d:.0} clean={d:.0} (suppressed to {d:.1}%)\n",
                        .{frame_count, mic_rms, clean_rms, (clean_rms / mic_rms) * 100});
                }
            }
        }

        frame_count += 1;
    }

    if (over_suppression > 0) {
        std.debug.print("\n  Total over-suppression frames: {d}\n", .{over_suppression});
        std.debug.print("  => Near-end speech is being heavily suppressed!\n", .{});
    } else if (suppression_count > 0) {
        std.debug.print("  Moderate near-end suppression in {d} frames\n", .{suppression_count});
    } else {
        std.debug.print("  No near-end suppression detected\n", .{});
    }

    mic_wav.deinit();
    ref_wav.deinit();
    clean_wav.deinit();

    std.debug.print("\n", .{});
}
