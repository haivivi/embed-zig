//! e2e: trait/codec — Verify audio encode/decode round-trip (Opus)
//!
//! Tests:
//!   1. Generate 1kHz triangle wave (multiple 20ms frames @ 16kHz)
//!   2. Encode PCM → Opus for several frames (codec warmup)
//!   3. Decode Opus → PCM
//!   4. Check correlation on last frame (after codec delay settles)
//!   5. Correlation > 0.7 → PASS

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const Codec = platform.Codec;

const SAMPLE_RATE: u32 = 16000;
const FRAME_MS: u32 = 20;
const FRAME_SIZE: u32 = SAMPLE_RATE * FRAME_MS / 1000; // 320 samples
const NUM_FRAMES: u32 = 5; // encode 5 frames, check last one
const FREQ_HZ: u32 = 1000;

fn runTests() !void {
    log.info("[e2e] START: trait/codec", .{});

    try testEncodeDecodeRoundtrip();

    log.info("[e2e] PASS: trait/codec", .{});
}

/// Generate one frame of 1kHz triangle wave starting at sample offset
fn generateTriangle(buf: []i16, offset: u32) void {
    const period: i32 = @intCast(SAMPLE_RATE / FREQ_HZ); // 16 samples per period
    const half: i32 = @divTrunc(period, 2);
    for (buf, 0..) |*s, i| {
        const pos: i32 = @intCast((offset + @as(u32, @intCast(i))) % @as(u32, @intCast(period)));
        // Triangle: -32767 → +32767 → -32767
        const val: i32 = if (pos < half)
            @divTrunc(pos * 2 * 32767, half) - 32767
        else
            32767 - @divTrunc((pos - half) * 2 * 32767, half);
        s.* = @intCast(std.math.clamp(val, -32767, 32767));
    }
}

fn testEncodeDecodeRoundtrip() !void {
    const allocator = platform.heap_allocator;

    var encoder = Codec.OpusEncoder.init(allocator, SAMPLE_RATE, 1, .voip, FRAME_MS) catch |err| {
        log.err("[e2e] FAIL: trait/codec/roundtrip — encoder init: {}", .{err});
        return error.EncoderInitFailed;
    };
    defer encoder.deinit();

    var decoder = Codec.OpusDecoder.init(allocator, SAMPLE_RATE, 1, FRAME_MS) catch |err| {
        log.err("[e2e] FAIL: trait/codec/roundtrip — decoder init: {}", .{err});
        return error.DecoderInitFailed;
    };
    defer decoder.deinit();

    // Encode + decode multiple frames to let codec warm up
    var last_input: [FRAME_SIZE]i16 = undefined;
    var last_output: [FRAME_SIZE]i16 = undefined;
    var total_encoded_bytes: usize = 0;

    for (0..NUM_FRAMES) |frame_idx| {
        var pcm_in: [FRAME_SIZE]i16 = undefined;
        generateTriangle(&pcm_in, @intCast(frame_idx * FRAME_SIZE));

        // Encode
        var opus_buf: [1024]u8 = undefined;
        const encoded = encoder.encode(&pcm_in, FRAME_SIZE, &opus_buf) catch |err| {
            log.err("[e2e] FAIL: trait/codec/roundtrip — encode frame {}: {}", .{ frame_idx, err });
            return error.EncodeFailed;
        };
        total_encoded_bytes += encoded.len;

        // Decode
        var pcm_out: [FRAME_SIZE]i16 = undefined;
        const decoded = decoder.decode(encoded, &pcm_out) catch |err| {
            log.err("[e2e] FAIL: trait/codec/roundtrip — decode frame {}: {}", .{ frame_idx, err });
            return error.DecodeFailed;
        };

        if (decoded.len != FRAME_SIZE) {
            log.err("[e2e] FAIL: trait/codec/roundtrip — decoded {} samples, expected {}", .{ decoded.len, FRAME_SIZE });
            return error.DecodeSizeMismatch;
        }

        // Save last frame for correlation check
        @memcpy(&last_input, &pcm_in);
        @memcpy(&last_output, pcm_out[0..FRAME_SIZE]);
    }

    log.info("[e2e] INFO: trait/codec — {} frames, {} bytes total", .{ NUM_FRAMES, total_encoded_bytes });

    // Compute normalized cross-correlation on last frame
    var sum_xy: i64 = 0;
    var sum_xx: i64 = 0;
    var sum_yy: i64 = 0;
    for (last_input, last_output) |x, y| {
        sum_xy += @as(i64, x) * @as(i64, y);
        sum_xx += @as(i64, x) * @as(i64, x);
        sum_yy += @as(i64, y) * @as(i64, y);
    }

    // |correlation| = |sum_xy| / sqrt(sum_xx * sum_yy)
    // Opus codec delay can invert phase, so use absolute correlation.
    // Check: sum_xy² * 100 > 49 * sum_xx * sum_yy (|threshold| = 0.7, 0.7² = 0.49)
    const pass = @as(i128, sum_xy) * @as(i128, sum_xy) * 100 > @as(i128, sum_xx) * @as(i128, sum_yy) * 49;

    if (!pass) {
        log.err("[e2e] FAIL: trait/codec/roundtrip — correlation too low (xy={}, xx={}, yy={})", .{ sum_xy, sum_xx, sum_yy });
        return error.CorrelationTooLow;
    }

    log.info("[e2e] PASS: trait/codec/roundtrip — {} bytes, correlation OK", .{total_encoded_bytes});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/codec — {}", .{err});
    };
}

test "e2e: trait/codec" {
    try runTests();
}
