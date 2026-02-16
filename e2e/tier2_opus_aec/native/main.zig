//! Opus Native Test — encode/decode verification on macOS

const std = @import("std");
const opus = @import("opus");

const log = std.log.scoped(.opus_test);

const SAMPLE_RATE: u32 = 16000;
const CHANNELS: u8 = 1;
const FRAME_MS: u32 = 20;
const FRAME_SAMPLES: usize = SAMPLE_RATE * FRAME_MS / 1000; // 320
const MAX_OPUS_FRAME: usize = 512;
const NUM_FRAMES: usize = 50;

pub fn main() void {
    const allocator = std.heap.c_allocator;

    log.info("==========================================", .{});
    log.info("Opus Native Test", .{});
    log.info("==========================================", .{});
    log.info("Version: {s}", .{std.mem.span(opus.getVersionString())});
    log.info("Encoder size: {} bytes", .{opus.Encoder.getSize(CHANNELS)});
    log.info("Decoder size: {} bytes", .{opus.Decoder.getSize(CHANNELS)});
    log.info("==========================================", .{});

    var encoder = opus.Encoder.init(allocator, SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("Encoder init: {}", .{err});
        return;
    };
    defer encoder.deinit(allocator);
    encoder.setBitrate(24000) catch {};
    encoder.setComplexity(5) catch {};
    encoder.setSignal(.voice) catch {};
    log.info("[enc] ready: 24kbps complexity=5", .{});

    var decoder = opus.Decoder.init(allocator, SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("Decoder init: {}", .{err});
        return;
    };
    defer decoder.deinit(allocator);
    log.info("[dec] ready", .{});

    var pcm: [FRAME_SAMPLES]i16 = undefined;
    var decoded: [FRAME_SAMPLES]i16 = undefined;
    var opus_buf: [MAX_OPUS_FRAME]u8 = undefined;

    var total_pcm: u64 = 0;
    var total_opus: u64 = 0;
    var total_enc_ns: u64 = 0;
    var total_dec_ns: u64 = 0;
    var phase: f32 = 0;
    const phase_inc = 440.0 * 2.0 * std.math.pi / @as(f32, @floatFromInt(SAMPLE_RATE));

    for (0..NUM_FRAMES) |i| {
        // Generate 440Hz sine
        for (&pcm) |*s| {
            s.* = @intFromFloat(@sin(phase) * 8000.0);
            phase += phase_inc;
            if (phase >= 2.0 * std.math.pi) phase -= 2.0 * std.math.pi;
        }

        // Encode
        var t = std.time.Timer.start() catch return;
        const encoded = encoder.encode(&pcm, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("encode #{}: {}", .{ i, err });
            return;
        };
        total_enc_ns += t.read();

        // Decode
        t = std.time.Timer.start() catch return;
        const samples = decoder.decode(encoded, &decoded, false) catch |err| {
            log.err("decode #{}: {}", .{ i, err });
            return;
        };
        total_dec_ns += t.read();

        total_pcm += FRAME_SAMPLES * 2;
        total_opus += encoded.len;

        if (i == 0 or i == NUM_FRAMES - 1) {
            log.info("  #{}: enc={}B dec={} samples", .{ i, encoded.len, samples.len });
        }
    }

    log.info("==========================================", .{});
    log.info("PCM: {} bytes  Opus: {} bytes  Ratio: {}:1", .{ total_pcm, total_opus, total_pcm / total_opus });
    log.info("Avg encode: {} us  decode: {} us", .{ total_enc_ns / NUM_FRAMES / 1000, total_dec_ns / NUM_FRAMES / 1000 });
    log.info("PASS", .{});
}
