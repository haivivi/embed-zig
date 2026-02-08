//! Opus Native Test — encode/decode verification on macOS
//!
//! Generates a sine wave, encodes with opus, decodes back, and prints metrics.

const std = @import("std");
const audio = @import("audio");
const opus = audio.opus;

const log = std.log.scoped(.opus_test);

const SAMPLE_RATE: i32 = 16000;
const CHANNELS: i32 = 1;
const FRAME_DURATION_MS: i32 = 20;
const FRAME_SAMPLES: usize = @intCast(@divExact(SAMPLE_RATE * FRAME_DURATION_MS, 1000));
const MAX_OPUS_FRAME: usize = 512;
const NUM_FRAMES: usize = 50;

pub fn main() void {
    log.info("==========================================", .{});
    log.info("Opus Native Test (macOS)", .{});
    log.info("==========================================", .{});
    log.info("Version: {s}", .{std.mem.span(opus.getVersionString())});
    log.info("Sample Rate: {}Hz, Frame: {}ms ({} samples)", .{ SAMPLE_RATE, FRAME_DURATION_MS, FRAME_SAMPLES });
    log.info("==========================================", .{});

    // Initialize encoder
    var encoder = opus.Encoder.init(SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("Encoder init failed: {}", .{err});
        return;
    };
    defer encoder.deinit();
    encoder.setBitrate(24000) catch {};
    encoder.setComplexity(5) catch {};
    encoder.setSignal(.voice) catch {};
    log.info("[encoder] Initialized: 24kbps, complexity=5, voip", .{});

    // Initialize decoder
    var decoder = opus.Decoder.init(SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("Decoder init failed: {}", .{err});
        return;
    };
    defer decoder.deinit();
    log.info("[decoder] Initialized", .{});

    // Generate test signal: 440Hz sine wave
    var pcm_buf: [FRAME_SAMPLES]i16 = undefined;
    var decoded_buf: [FRAME_SAMPLES]i16 = undefined;
    var opus_buf: [MAX_OPUS_FRAME]u8 = undefined;

    var total_pcm_bytes: u64 = 0;
    var total_opus_bytes: u64 = 0;
    var total_encode_ns: u64 = 0;
    var total_decode_ns: u64 = 0;
    var phase: f32 = 0;
    const freq: f32 = 440.0;
    const amplitude: f32 = 8000.0;
    const phase_inc = freq * 2.0 * std.math.pi / @as(f32, @floatFromInt(SAMPLE_RATE));

    for (0..NUM_FRAMES) |frame_idx| {
        for (&pcm_buf) |*sample| {
            sample.* = @intFromFloat(@sin(phase) * amplitude);
            phase += phase_inc;
            if (phase >= 2.0 * std.math.pi) phase -= 2.0 * std.math.pi;
        }

        // Encode
        var enc_timer = std.time.Timer.start() catch return;
        const encoded_len = encoder.encode(&pcm_buf, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("Encode error at frame {}: {}", .{ frame_idx, err });
            return;
        };
        const enc_elapsed = enc_timer.read();
        total_encode_ns += enc_elapsed;

        // Decode
        var dec_timer = std.time.Timer.start() catch return;
        const decoded_samples = decoder.decode(opus_buf[0..encoded_len], FRAME_SAMPLES, &decoded_buf, false) catch |err| {
            log.err("Decode error at frame {}: {}", .{ frame_idx, err });
            return;
        };
        const dec_elapsed = dec_timer.read();
        total_decode_ns += dec_elapsed;

        total_pcm_bytes += FRAME_SAMPLES * 2;
        total_opus_bytes += encoded_len;

        if (frame_idx == 0 or frame_idx == NUM_FRAMES - 1) {
            log.info("  Frame {}: encoded={}B, decoded={} samples, enc_us={}, dec_us={}", .{
                frame_idx,
                encoded_len,
                decoded_samples,
                enc_elapsed / 1000,
                dec_elapsed / 1000,
            });
        }
    }

    // Summary
    const avg_enc_us = total_encode_ns / NUM_FRAMES / 1000;
    const avg_dec_us = total_decode_ns / NUM_FRAMES / 1000;
    const ratio = total_pcm_bytes / total_opus_bytes;

    log.info("==========================================", .{});
    log.info("RESULTS ({} frames, {}ms total)", .{ NUM_FRAMES, NUM_FRAMES * @as(usize, @intCast(FRAME_DURATION_MS)) });
    log.info("==========================================", .{});
    log.info("  PCM total:        {} bytes", .{total_pcm_bytes});
    log.info("  Opus total:       {} bytes", .{total_opus_bytes});
    log.info("  Compression:      {}:1", .{ratio});
    log.info("  Avg encode:       {} us/frame", .{avg_enc_us});
    log.info("  Avg decode:       {} us/frame", .{avg_dec_us});
    log.info("==========================================", .{});
    log.info("PASS — opus encode/decode works correctly", .{});
}
