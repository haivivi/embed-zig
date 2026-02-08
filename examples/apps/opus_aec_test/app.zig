//! Opus AEC Loopback Test
//!
//! Pipeline: mic -> AEC -> opus encode -> Channel -> opus decode -> speaker
//!
//! Two FreeRTOS tasks connected by a Channel(OpusFrame):
//! - Encoder task: reads AEC-processed mic audio, encodes to opus, sends to channel
//! - Decoder task: receives opus frames, decodes to PCM, writes to speaker
//!
//! Metrics collected:
//! - Heap usage (before/after encoder+decoder init)
//! - Encode/decode latency per frame (us)
//! - Compression ratio (PCM bytes vs opus frame bytes)
//! - Channel backpressure count (trySend failures)

const std = @import("std");
const esp = @import("esp");
const audio = @import("audio");
// Channel/WaitGroup/CancellationToken available for future dual-task version
// const channel_mod = @import("channel");
// const waitgroup = @import("waitgroup");
// const cancellation = @import("cancellation");

const idf = esp.idf;
const heap = idf.heap;
const EspRt = idf.runtime;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// ============================================================================
// Audio Parameters
// ============================================================================

const SAMPLE_RATE: i32 = 16000; // mic native sample rate
const CHANNELS: i32 = 1;
const FRAME_DURATION_MS: i32 = 20; // 20ms opus frame
const FRAME_SAMPLES: usize = @intCast(@divExact(SAMPLE_RATE * FRAME_DURATION_MS, 1000)); // 320 samples
const PCM_FRAME_BYTES: usize = FRAME_SAMPLES * 2; // 640 bytes (i16)
const MAX_OPUS_FRAME: usize = 512; // max encoded frame size
const OPUS_BITRATE: i32 = 24000; // 24 kbps
const OPUS_COMPLEXITY: i32 = 5; // mid complexity

const MIC_GAIN: i32 = 8; // amplify mic input
const SPEAKER_VOLUME: u8 = 150;

const TEST_DURATION_MS: u64 = 30_000; // 30 seconds
const METRIC_INTERVAL_MS: u64 = 5_000; // log metrics every 5s

// ============================================================================
// Opus Frame — passed through Channel
// ============================================================================

// ============================================================================
// Metrics
// ============================================================================

const Metrics = struct {
    total_encoded: u64 = 0,
    total_pcm_bytes: u64 = 0,
    total_opus_bytes: u64 = 0,
    encode_time_us: u64 = 0,
    decode_time_us: u64 = 0,
    encode_count: u64 = 0,
    decode_count: u64 = 0,
};

// ============================================================================
// Main Entry Point
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Opus AEC Loopback Test", .{});
    log.info("==========================================", .{});
    log.info("Board:       {s}", .{platform.Hardware.name});
    log.info("Sample Rate: {}Hz", .{SAMPLE_RATE});
    log.info("Frame:       {}ms ({} samples)", .{ FRAME_DURATION_MS, FRAME_SAMPLES });
    log.info("Bitrate:     {}bps", .{OPUS_BITRATE});
    log.info("Complexity:  {}", .{OPUS_COMPLEXITY});
    log.info("Duration:    {}s", .{TEST_DURATION_MS / 1000});
    log.info("==========================================", .{});

    // Initialize board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    // Enable PA
    board.pa_switch.on() catch |err| {
        log.err("Failed to enable PA: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};

    board.audio.setVolume(SPEAKER_VOLUME);

    log.info("Board initialized, PA enabled, volume={}", .{SPEAKER_VOLUME});

    // ========================================================================
    // Heap metrics: before opus init
    // ========================================================================

    const heap_before_internal = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const heap_before_psram = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] Before opus init: internal={}KB, PSRAM={}KB", .{
        heap_before_internal / 1024,
        heap_before_psram / 1024,
    });

    // ========================================================================
    // Setup Channel + Metrics
    // ========================================================================

    // ========================================================================
    // Initialize opus encoder/decoder on main task
    // ========================================================================

    log.info("Initializing opus encoder...", .{});
    var encoder = audio.opus.Encoder.init(SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("Failed to init opus encoder: {}", .{err});
        return;
    };
    defer encoder.deinit();

    encoder.setBitrate(OPUS_BITRATE) catch {};
    encoder.setComplexity(OPUS_COMPLEXITY) catch {};
    encoder.setSignal(.voice) catch {};
    log.info("Opus encoder ready: {}bps, complexity={}", .{ OPUS_BITRATE, OPUS_COMPLEXITY });

    log.info("Initializing opus decoder...", .{});
    var decoder = audio.opus.Decoder.init(SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("Failed to init opus decoder: {}", .{err});
        return;
    };
    defer decoder.deinit();
    log.info("Opus decoder ready", .{});

    // Heap after init
    const heap_after_internal = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const heap_after_psram = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] After opus init: internal={}KB, PSRAM={}KB", .{
        heap_after_internal / 1024,
        heap_after_psram / 1024,
    });
    log.info("[heap] Opus overhead: internal={}KB, PSRAM={}KB", .{
        (heap_before_internal - heap_after_internal) / 1024,
        (heap_before_psram - heap_after_psram) / 1024,
    });

    log.info("Running single-task loopback for {}s...", .{TEST_DURATION_MS / 1000});
    log.info("Speak into the mic — audio loops through opus codec.", .{});

    // ========================================================================
    // Single-task encode/decode loopback (same as aec_test pattern)
    // ========================================================================

    var pcm_buf: [FRAME_SAMPLES]i16 = undefined;
    var pcm_accum: [FRAME_SAMPLES]i16 = undefined;
    var decoded_buf: [FRAME_SAMPLES]i16 = undefined;
    var opus_buf: [MAX_OPUS_FRAME]u8 = undefined;
    var read_accum: usize = 0;

    var metrics = Metrics{};
    const start_ms = idf.time.nowMs();
    var last_report_ms: u64 = 0;

    while (idf.time.nowMs() - start_ms < TEST_DURATION_MS) {
        // Read mic (AEC-processed)
        const samples_read = board.audio.readMic(&pcm_buf) catch |err| {
            log.err("[mic] Read error: {}", .{err});
            platform.time.sleepMs(10);
            continue;
        };

        if (samples_read == 0) {
            platform.time.sleepMs(1);
            continue;
        }

        // Apply gain
        for (0..samples_read) |i| {
            const amplified: i32 = @as(i32, pcm_buf[i]) * MIC_GAIN;
            pcm_buf[i] = @intCast(std.math.clamp(amplified, std.math.minInt(i16), std.math.maxInt(i16)));
        }

        // Accumulate until full opus frame
        const to_copy = @min(samples_read, FRAME_SAMPLES - read_accum);
        @memcpy(pcm_accum[read_accum..][0..to_copy], pcm_buf[0..to_copy]);
        read_accum += to_copy;

        if (read_accum < FRAME_SAMPLES) continue;
        read_accum = 0;

        // Encode
        const t0 = idf.time.nowUs();
        const encoded_len = encoder.encode(&pcm_accum, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("[enc] Encode error: {}", .{err});
            continue;
        };
        const t1 = idf.time.nowUs();

        // Decode
        const decoded_samples = decoder.decode(opus_buf[0..encoded_len], FRAME_SAMPLES, &decoded_buf, false) catch |err| {
            log.err("[dec] Decode error: {}", .{err});
            continue;
        };
        const t2 = idf.time.nowUs();

        // Write to speaker
        if (decoded_samples > 0) {
            _ = board.audio.writeSpeaker(decoded_buf[0..@intCast(decoded_samples)]) catch |err| {
                log.err("[spk] Write error: {}", .{err});
                continue;
            };
        }

        // Update metrics
        metrics.total_encoded += 1;
        metrics.total_pcm_bytes += PCM_FRAME_BYTES;
        metrics.total_opus_bytes += encoded_len;
        metrics.encode_time_us += (t1 - t0);
        metrics.decode_time_us += (t2 - t1);
        metrics.encode_count += 1;
        metrics.decode_count += 1;

        // Periodic report
        const now_ms = idf.time.nowMs();
        if (now_ms - start_ms - last_report_ms >= METRIC_INTERVAL_MS) {
            last_report_ms = now_ms - start_ms;
            printMetrics(&metrics, last_report_ms);
        }
    }

    // ========================================================================
    // Final report
    // ========================================================================

    log.info("==========================================", .{});
    log.info("FINAL REPORT", .{});
    log.info("==========================================", .{});
    printMetrics(&metrics, TEST_DURATION_MS);

    const heap_final_internal = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const heap_final_psram = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] Final: internal={}KB, PSRAM={}KB", .{
        heap_final_internal / 1024,
        heap_final_psram / 1024,
    });
    log.info("[heap] Min free internal: {}KB", .{
        heap.heap_caps_get_minimum_free_size(heap.MALLOC_CAP_INTERNAL) / 1024,
    });
    log.info("==========================================", .{});

    // Keep alive
    while (true) {
        platform.time.sleepMs(5000);
    }
}

fn printMetrics(m: *const Metrics, elapsed_ms: u64) void {
    const avg_enc_us: u64 = if (m.encode_count > 0) m.encode_time_us / m.encode_count else 0;
    const avg_dec_us: u64 = if (m.decode_count > 0) m.decode_time_us / m.decode_count else 0;
    const ratio: u64 = if (m.total_opus_bytes > 0) (m.total_pcm_bytes * 100) / m.total_opus_bytes else 0;

    log.info("[metrics] t={}s encoded={} decoded={} enc_avg={}us dec_avg={}us ratio={}:1 backpressure={}", .{
        elapsed_ms / 1000,
        m.total_encoded,
        m.total_decoded,
        avg_enc_us,
        avg_dec_us,
        ratio / 100,
        m.backpressure_count,
    });
}
