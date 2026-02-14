//! Opus Encode/Decode Test — Pure sine wave roundtrip
//!
//! 1. Generate 1 second of 440Hz sine wave (PCM i16)
//! 2. Encode with Opus (FIXED_POINT, complexity=0)
//! 3. Decode back to PCM
//! 4. Compare: correlation, SNR, max error
//!
//! No WiFi, no mic, no speaker — pure codec test.

const std = @import("std");
const opus = @import("opus");

const platform = @import("platform.zig");
const log = platform.log;
const time = platform.time;
const heap = platform.heap;

// ============================================================================
// Parameters
// ============================================================================

const SAMPLE_RATE: u32 = 16000;
const CHANNELS: u8 = 1;
const FRAME_MS: u32 = 20;
const FRAME_SAMPLES: usize = SAMPLE_RATE * FRAME_MS / 1000; // 320
const MAX_OPUS_BYTES: usize = 512;
const BITRATE: u32 = 24000;
const TONE_HZ: u32 = 440;
const TEST_FRAMES: usize = SAMPLE_RATE / FRAME_SAMPLES; // 50 frames = 1 second
const AMPLITUDE: i16 = 16000;

// ============================================================================
// Sine wave generation (64-entry quarter-wave lookup table)
// ============================================================================

/// Quarter-wave sine table: sin(i/64 * pi/2) * 32767, i=0..63
/// Generated at comptime. Full wave via symmetry.
const sine_quarter = blk: {
    // Compute at comptime (float OK here, result is const array)
    var table: [64]i16 = undefined;
    for (0..64) |i| {
        const angle: f64 = @as(f64, @floatFromInt(i)) / 64.0 * (3.14159265358979323846 / 2.0);
        // Use Taylor series: sin(x) = x - x^3/6 + x^5/120 - x^7/5040
        const x = angle;
        const x3 = x * x * x;
        const x5 = x3 * x * x;
        const x7 = x5 * x * x;
        const x9 = x7 * x * x;
        const s = x - x3 / 6.0 + x5 / 120.0 - x7 / 5040.0 + x9 / 362880.0;
        const val: i32 = @intFromFloat(s * 32767.0);
        table[i] = @intCast(if (val > 32767) 32767 else if (val < -32767) -32767 else val);
    }
    break :blk table;
};

fn generateSine(buf: []i16, start_sample: usize) void {
    for (buf, 0..) |*sample, i| {
        const global_idx = start_sample + i;
        // Phase: 0..255 maps to 0..2pi
        const phase: u32 = @intCast(((@as(u64, global_idx) * TONE_HZ * 256) / SAMPLE_RATE) % 256);

        // Quarter-wave lookup with symmetry
        const quadrant = phase / 64;
        const idx: u32 = switch (quadrant) {
            0 => phase,           // 0..63: ascending
            1 => 127 - phase,     // 64..127: descending
            2 => phase - 128,     // 128..191: ascending (negative)
            3 => 255 - phase,     // 192..255: descending (negative)
            else => unreachable,
        };

        const magnitude: i32 = sine_quarter[@min(idx, 63)];
        const sign: i32 = if (phase < 128) 1 else -1;

        // Scale from ±32767 to ±AMPLITUDE
        sample.* = @intCast(@divTrunc(magnitude * sign * AMPLITUDE, 32767));
    }
}

// ============================================================================
// Statistics
// ============================================================================

/// Find best alignment offset using cross-correlation (Opus has codec delay).
fn findOffset(original: []const i16, decoded: []const i16) usize {
    const max_shift: usize = @min(FRAME_SAMPLES * 3, original.len / 4); // Search up to 3 frames
    var best_corr: i64 = -2147483648;
    var best_shift: usize = 0;

    var shift: usize = 0;
    while (shift < max_shift) : (shift += 4) { // Step by 4 for speed
        var corr: i64 = 0;
        const len = @min(original.len - shift, decoded.len - shift);
        const check_len = @min(len, FRAME_SAMPLES * 5); // Check 5 frames
        for (0..check_len) |i| {
            corr += @as(i64, original[i]) * @as(i64, decoded[i + shift]);
        }
        if (corr > best_corr) {
            best_corr = corr;
            best_shift = shift;
        }
    }
    return best_shift;
}

fn computeStats(original: []const i16, decoded: []const i16) struct { max_err: u32, mean_err: u32, snr_db: i32, offset: usize } {
    // Find best alignment (Opus has algorithmic delay)
    const offset = findOffset(original, decoded);

    var signal_energy: u64 = 0;
    var noise_energy: u64 = 0;
    var max_err: u32 = 0;
    var sum_err: u64 = 0;

    // Skip first 5 frames (startup transient) + apply offset
    const skip = FRAME_SAMPLES * 5;
    const start = skip;
    const len = @min(original.len - start, decoded.len - start - offset);
    for (0..len) |i| {
        const s: i32 = original[start + i];
        const d: i32 = decoded[start + i + offset];
        const diff: i32 = s - d;

        signal_energy += @intCast(@as(u64, @intCast(s * s)));
        noise_energy += @intCast(@as(u64, @intCast(diff * diff)));

        const abs_diff: u32 = @intCast(if (diff < 0) -diff else diff);
        if (abs_diff > max_err) max_err = abs_diff;
        sum_err += abs_diff;
    }

    const mean_err: u32 = if (len > 0) @intCast(sum_err / len) else 0;

    // SNR = 10 * log10(signal / noise) ≈ 3 * log2(signal/noise)
    var snr_db: i32 = 0;
    if (noise_energy > 0 and signal_energy > 0) {
        var ratio = signal_energy / noise_energy;
        var bits: i32 = 0;
        while (ratio > 1) : (ratio >>= 1) {
            bits += 1;
        }
        snr_db = bits * 3;
    } else if (noise_energy == 0) {
        snr_db = 99;
    }

    return .{ .max_err = max_err, .mean_err = mean_err, .snr_db = snr_db, .offset = offset };
}

// ============================================================================
// Main test
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  Opus Encode/Decode Test", .{});
    log.info("  {}Hz sine, {}Hz sample rate", .{ TONE_HZ, SAMPLE_RATE });
    log.info("  {} frames x {}ms = {}ms", .{ TEST_FRAMES, FRAME_MS, TEST_FRAMES * FRAME_MS });
    log.info("  Bitrate: {} bps, Complexity: 0", .{BITRATE});
    log.info("==========================================", .{});

    // --- Init encoder ---
    log.info("Initializing encoder...", .{});
    const enc_start = time.nowMs();
    var encoder = opus.Encoder.init(heap, SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("Encoder init failed: {}", .{err});
        return;
    };
    encoder.setComplexity(0) catch {};
    encoder.setSignal(.voice) catch {};
    encoder.setBitrate(BITRATE) catch {};
    log.info("Encoder init: {} ms", .{time.nowMs() - enc_start});

    // --- Init decoder ---
    log.info("Initializing decoder...", .{});
    const dec_start = time.nowMs();
    var decoder = opus.Decoder.init(heap, SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("Decoder init failed: {}", .{err});
        encoder.deinit(heap);
        return;
    };
    log.info("Decoder init: {} ms", .{time.nowMs() - dec_start});

    // --- Buffers ---
    var pcm_in: [FRAME_SAMPLES]i16 = undefined;
    var pcm_out: [FRAME_SAMPLES]i16 = undefined;
    var opus_buf: [MAX_OPUS_BYTES]u8 = undefined;

    // Accumulate all original and decoded for final comparison
    var all_original: [FRAME_SAMPLES * TEST_FRAMES]i16 = undefined;
    var all_decoded: [FRAME_SAMPLES * TEST_FRAMES]i16 = undefined;

    var total_opus_bytes: usize = 0;
    var total_enc_ms: u64 = 0;
    var total_dec_ms: u64 = 0;

    log.info("", .{});
    log.info("Running {} frames...", .{TEST_FRAMES});

    for (0..TEST_FRAMES) |frame_idx| {
        // Generate sine
        generateSine(&pcm_in, frame_idx * FRAME_SAMPLES);
        @memcpy(all_original[frame_idx * FRAME_SAMPLES ..][0..FRAME_SAMPLES], &pcm_in);

        // Encode
        const t0 = time.nowMs();
        const encoded = encoder.encode(&pcm_in, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("Encode frame {} failed: {}", .{ frame_idx, err });
            break;
        };
        const t1 = time.nowMs();
        total_enc_ms += t1 - t0;
        total_opus_bytes += encoded.len;

        // Decode
        const decoded = decoder.decode(encoded, &pcm_out, false) catch |err| {
            log.err("Decode frame {} failed: {}", .{ frame_idx, err });
            break;
        };
        const t2 = time.nowMs();
        total_dec_ms += t2 - t1;

        @memcpy(all_decoded[frame_idx * FRAME_SAMPLES ..][0..FRAME_SAMPLES], decoded);

        // Log every 10 frames
        if ((frame_idx + 1) % 10 == 0) {
            log.info("  Frame {}/{}: opus={} bytes, enc={}ms, dec={}ms", .{
                frame_idx + 1, TEST_FRAMES, encoded.len, t1 - t0, t2 - t1,
            });
        }
    }

    // --- Results ---
    const pcm_bytes = TEST_FRAMES * FRAME_SAMPLES * 2;
    const ratio = if (total_opus_bytes > 0) pcm_bytes / total_opus_bytes else 0;
    const stats = computeStats(&all_original, &all_decoded);

    log.info("", .{});
    log.info("========== Results ==========", .{});
    log.info("PCM:  {} bytes ({} samples)", .{ pcm_bytes, TEST_FRAMES * FRAME_SAMPLES });
    log.info("Opus: {} bytes ({}:1 compression)", .{ total_opus_bytes, ratio });
    log.info("Encode: {} ms total ({} ms/frame avg)", .{ total_enc_ms, total_enc_ms / TEST_FRAMES });
    log.info("Decode: {} ms total ({} ms/frame avg)", .{ total_dec_ms, total_dec_ms / TEST_FRAMES });
    log.info("Codec delay: {} samples ({} ms)", .{ stats.offset, stats.offset * 1000 / SAMPLE_RATE });
    log.info("Max error:  {} (of {})", .{ stats.max_err, AMPLITUDE });
    log.info("Mean error: {}", .{stats.mean_err});
    log.info("SNR: ~{} dB", .{stats.snr_db});

    if (stats.snr_db >= 15) {
        log.info("PASS: SNR >= 15 dB — Opus roundtrip OK", .{});
    } else {
        log.err("FAIL: SNR {} dB too low", .{stats.snr_db});
    }
    log.info("=============================", .{});

    // Cleanup
    decoder.deinit(heap);
    encoder.deinit(heap);
}
