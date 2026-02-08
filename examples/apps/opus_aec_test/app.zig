//! Opus AEC Loopback Test
//!
//! Pipeline: mic -> AEC -> opus encode -> opus decode -> speaker
//! Single-task, same pattern as aec_test.
//!
//! Metrics: heap, encode/decode latency, compression ratio.

const std = @import("std");
const esp = @import("esp");
const audio = @import("audio");
const opus = audio.opus;

const idf = esp.idf;
const heap = idf.heap;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// ============================================================================
// Parameters
// ============================================================================

const SAMPLE_RATE: u32 = 16000;
const CHANNELS: u8 = 1;
const FRAME_MS: u32 = 20;
const FRAME_SAMPLES: usize = SAMPLE_RATE * FRAME_MS / 1000; // 320
const PCM_FRAME_BYTES: usize = FRAME_SAMPLES * 2; // 640
const MAX_OPUS_FRAME: usize = 512;
const BITRATE: u32 = 24000;
const COMPLEXITY: u4 = 0; // lowest for ESP32 speed
const MIC_GAIN: i32 = 8;
const SPEAKER_VOLUME: u8 = 150;
const TEST_DURATION_MS: u64 = 30_000;
const METRIC_INTERVAL_MS: u64 = 5_000;

// ============================================================================
// Metrics
// ============================================================================

const Metrics = struct {
    frames: u64 = 0,
    pcm_bytes: u64 = 0,
    opus_bytes: u64 = 0,
    enc_us: u64 = 0,
    dec_us: u64 = 0,
};

// ============================================================================
// Entry
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Opus AEC Loopback Test", .{});
    log.info("==========================================", .{});
    log.info("Board:   {s}", .{platform.Hardware.name});
    log.info("Rate:    {}Hz  Frame: {}ms ({} samples)", .{ SAMPLE_RATE, FRAME_MS, FRAME_SAMPLES });
    log.info("Bitrate: {}bps  Complexity: {}", .{ BITRATE, COMPLEXITY });
    log.info("Encoder size: {} bytes", .{opus.Encoder.getSize(CHANNELS)});
    log.info("Decoder size: {} bytes", .{opus.Decoder.getSize(CHANNELS)});
    log.info("==========================================", .{});

    // Board init
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init: {}", .{err});
        return;
    };
    defer board.deinit();

    board.pa_switch.on() catch |err| {
        log.err("PA on: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};
    board.audio.setVolume(SPEAKER_VOLUME);
    log.info("Board ready, PA on, vol={}", .{SPEAKER_VOLUME});

    // Heap before
    const h0_int = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const h0_ps = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] before: int={}KB psram={}KB", .{ h0_int / 1024, h0_ps / 1024 });

    // Opus init — allocate on PSRAM
    const alloc = heap.psram;

    log.info("opus encoder init...", .{});
    var encoder = opus.Encoder.init(alloc, SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("encoder init: {}", .{err});
        return;
    };
    defer encoder.deinit(alloc);
    encoder.setBitrate(BITRATE) catch {};
    encoder.setComplexity(COMPLEXITY) catch {};
    encoder.setSignal(.voice) catch {};

    log.info("opus decoder init...", .{});
    var decoder = opus.Decoder.init(alloc, SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("decoder init: {}", .{err});
        return;
    };
    defer decoder.deinit(alloc);

    // Heap after
    const h1_int = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const h1_ps = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] after:  int={}KB psram={}KB", .{ h1_int / 1024, h1_ps / 1024 });
    log.info("[heap] opus:   int={}KB psram={}KB", .{ (h0_int -| h1_int) / 1024, (h0_ps -| h1_ps) / 1024 });

    log.info("Loopback running {}s — speak into mic", .{TEST_DURATION_MS / 1000});

    // Buffers
    var mic_buf: [FRAME_SAMPLES]i16 = undefined;
    var accum: [FRAME_SAMPLES]i16 = undefined;
    var dec_buf: [FRAME_SAMPLES]i16 = undefined;
    var opus_buf: [MAX_OPUS_FRAME]u8 = undefined;
    var accum_n: usize = 0;

    var m = Metrics{};
    const t_start = idf.time.nowMs();
    var t_last_report: u64 = 0;

    while (idf.time.nowMs() - t_start < TEST_DURATION_MS) {
        // Read AEC mic
        const n_read = board.audio.readMic(&mic_buf) catch |err| {
            log.err("mic: {}", .{err});
            platform.time.sleepMs(10);
            continue;
        };
        if (n_read == 0) {
            platform.time.sleepMs(1);
            continue;
        }

        // Gain
        for (0..n_read) |i| {
            const v: i32 = @as(i32, mic_buf[i]) * MIC_GAIN;
            mic_buf[i] = @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
        }

        // Accumulate to opus frame size
        const n_copy = @min(n_read, FRAME_SAMPLES - accum_n);
        @memcpy(accum[accum_n..][0..n_copy], mic_buf[0..n_copy]);
        accum_n += n_copy;
        if (accum_n < FRAME_SAMPLES) continue;
        accum_n = 0;

        // Encode
        const t0 = idf.time.nowUs();
        const encoded = encoder.encode(&accum, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("enc: {}", .{err});
            continue;
        };
        const t1 = idf.time.nowUs();

        // Decode
        const decoded = decoder.decode(encoded, &dec_buf, false) catch |err| {
            log.err("dec: {}", .{err});
            continue;
        };
        const t2 = idf.time.nowUs();

        // Speaker
        if (decoded.len > 0) {
            _ = board.audio.writeSpeaker(decoded) catch |err| {
                log.err("spk: {}", .{err});
                continue;
            };
        }

        // Metrics
        m.frames += 1;
        m.pcm_bytes += PCM_FRAME_BYTES;
        m.opus_bytes += encoded.len;
        m.enc_us += (t1 - t0);
        m.dec_us += (t2 - t1);

        const elapsed = idf.time.nowMs() - t_start;
        if (elapsed - t_last_report >= METRIC_INTERVAL_MS) {
            t_last_report = elapsed;
            report(&m, elapsed);
        }
    }

    // Final
    log.info("==========================================", .{});
    log.info("FINAL", .{});
    report(&m, TEST_DURATION_MS);
    const hf_int = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const hf_ps = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] final: int={}KB psram={}KB min_int={}KB", .{
        hf_int / 1024,
        hf_ps / 1024,
        heap.heap_caps_get_minimum_free_size(heap.MALLOC_CAP_INTERNAL) / 1024,
    });
    log.info("==========================================", .{});

    while (true) {
        platform.time.sleepMs(5000);
    }
}

fn report(m: *const Metrics, elapsed_ms: u64) void {
    const avg_enc = if (m.frames > 0) m.enc_us / m.frames else 0;
    const avg_dec = if (m.frames > 0) m.dec_us / m.frames else 0;
    const ratio = if (m.opus_bytes > 0) m.pcm_bytes / m.opus_bytes else 0;
    log.info("[{}s] frames={} enc={}us dec={}us ratio={}:1 opus={}B", .{
        elapsed_ms / 1000, m.frames, avg_enc, avg_dec, ratio, m.opus_bytes,
    });
}
