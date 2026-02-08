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
const channel_mod = @import("channel");
const waitgroup = @import("waitgroup");
const cancellation = @import("cancellation");

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

const OpusFrame = struct {
    data: [MAX_OPUS_FRAME]u8,
    len: usize,
};

const FrameChannel = channel_mod.Channel(OpusFrame, 8, EspRt);
const WG = waitgroup.WaitGroup(EspRt);

// ============================================================================
// Shared Metrics (atomic-safe via single-writer per field)
// ============================================================================

const Metrics = struct {
    // Written by encoder task
    total_encoded: u64 = 0,
    total_pcm_bytes: u64 = 0,
    total_opus_bytes: u64 = 0,
    encode_time_us: u64 = 0,
    encode_count: u64 = 0,
    backpressure_count: u64 = 0,

    // Written by decoder task
    total_decoded: u64 = 0,
    decode_time_us: u64 = 0,
    decode_count: u64 = 0,
};

// ============================================================================
// Encoder Task Context
// ============================================================================

const EncoderCtx = struct {
    ch: *FrameChannel,
    board: *Board,
    cancel: *cancellation.CancellationToken,
    metrics: *Metrics,
};

fn encoderTask(raw: ?*anyopaque) void {
    const ctx: *EncoderCtx = @ptrCast(@alignCast(raw));
    log.info("[encoder] Starting opus encoder task", .{});

    var encoder = audio.opus.Encoder.init(SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("[encoder] Failed to init opus encoder: {}", .{err});
        return;
    };
    defer encoder.deinit();

    encoder.setBitrate(OPUS_BITRATE) catch {};
    encoder.setComplexity(OPUS_COMPLEXITY) catch {};
    encoder.setSignal(.voice) catch {};

    log.info("[encoder] Opus encoder ready: {}bps, complexity={}", .{ OPUS_BITRATE, OPUS_COMPLEXITY });

    var pcm_buf: [FRAME_SAMPLES]i16 = undefined;
    var opus_buf: [MAX_OPUS_FRAME]u8 = undefined;
    var read_accum: usize = 0;
    var pcm_accum: [FRAME_SAMPLES]i16 = undefined;

    while (!ctx.cancel.isCancelled()) {
        // Read mic samples (AEC-processed)
        const samples_read = ctx.board.audio.readMic(&pcm_buf) catch |err| {
            log.err("[encoder] Mic read error: {}", .{err});
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

        // Accumulate until we have a full opus frame
        const to_copy = @min(samples_read, FRAME_SAMPLES - read_accum);
        @memcpy(pcm_accum[read_accum..][0..to_copy], pcm_buf[0..to_copy]);
        read_accum += to_copy;

        if (read_accum < FRAME_SAMPLES) continue;
        read_accum = 0;

        // Encode full frame
        const t0 = idf.time.nowUs();
        const encoded_len = encoder.encode(&pcm_accum, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("[encoder] Encode error: {}", .{err});
            continue;
        };
        const t1 = idf.time.nowUs();

        // Update metrics
        ctx.metrics.total_encoded += 1;
        ctx.metrics.total_pcm_bytes += PCM_FRAME_BYTES;
        ctx.metrics.total_opus_bytes += encoded_len;
        ctx.metrics.encode_time_us += (t1 - t0);
        ctx.metrics.encode_count += 1;

        // Send to decoder via channel (non-blocking to detect backpressure)
        var frame: OpusFrame = undefined;
        @memcpy(frame.data[0..encoded_len], opus_buf[0..encoded_len]);
        frame.len = encoded_len;

        ctx.ch.trySend(frame) catch |err| switch (err) {
            error.Closed => break,
            error.Full => {
                ctx.metrics.backpressure_count += 1;
                // Blocking send as fallback
                ctx.ch.send(frame) catch break;
            },
        };
    }

    log.info("[encoder] Encoder task exiting", .{});
}

// ============================================================================
// Decoder Task Context
// ============================================================================

const DecoderCtx = struct {
    ch: *FrameChannel,
    board: *Board,
    cancel: *cancellation.CancellationToken,
    metrics: *Metrics,
};

fn decoderTask(raw: ?*anyopaque) void {
    const ctx: *DecoderCtx = @ptrCast(@alignCast(raw));
    log.info("[decoder] Starting opus decoder task", .{});

    var decoder = audio.opus.Decoder.init(SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("[decoder] Failed to init opus decoder: {}", .{err});
        return;
    };
    defer decoder.deinit();

    log.info("[decoder] Opus decoder ready", .{});

    var pcm_buf: [FRAME_SAMPLES]i16 = undefined;

    while (!ctx.cancel.isCancelled()) {
        // Receive opus frame from channel
        const frame = ctx.ch.recv() orelse break; // channel closed

        // Decode
        const t0 = idf.time.nowUs();
        const decoded_samples = decoder.decode(frame.data[0..frame.len], FRAME_SAMPLES, &pcm_buf, false) catch |err| {
            log.err("[decoder] Decode error: {}", .{err});
            continue;
        };
        const t1 = idf.time.nowUs();

        // Update metrics
        ctx.metrics.total_decoded += 1;
        ctx.metrics.decode_time_us += (t1 - t0);
        ctx.metrics.decode_count += 1;

        // Write to speaker
        if (decoded_samples > 0) {
            _ = ctx.board.audio.writeSpeaker(pcm_buf[0..@intCast(decoded_samples)]) catch |err| {
                log.err("[decoder] Speaker write error: {}", .{err});
                continue;
            };
        }
    }

    log.info("[decoder] Decoder task exiting", .{});
}

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

    var ch = FrameChannel.init();
    defer ch.deinit();

    var cancel = cancellation.CancellationToken.init();
    var metrics = Metrics{};

    // ========================================================================
    // Spawn encoder + decoder tasks
    // ========================================================================

    var wg = WG.init(heap.psram);
    defer wg.deinit();

    var enc_ctx = EncoderCtx{
        .ch = &ch,
        .board = &board,
        .cancel = &cancel,
        .metrics = &metrics,
    };

    var dec_ctx = DecoderCtx{
        .ch = &ch,
        .board = &board,
        .cancel = &cancel,
        .metrics = &metrics,
    };

    wg.go("opus-enc", encoderTask, @ptrCast(&enc_ctx), .{
        .stack_size = 16384,
        .priority = 15,
        .allocator = heap.iram,
    }) catch |err| {
        log.err("Failed to spawn encoder task: {}", .{err});
        return;
    };

    wg.go("opus-dec", decoderTask, @ptrCast(&dec_ctx), .{
        .stack_size = 16384,
        .priority = 15,
        .allocator = heap.iram,
    }) catch |err| {
        log.err("Failed to spawn decoder task: {}", .{err});
        return;
    };

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

    log.info("Tasks started. Running for {}s...", .{TEST_DURATION_MS / 1000});
    log.info("Speak into the mic — audio should loop through opus codec.", .{});

    // ========================================================================
    // Metric reporting loop
    // ========================================================================

    var elapsed_ms: u64 = 0;
    const interval_ms: u64 = 100;
    var last_report_ms: u64 = 0;

    while (elapsed_ms < TEST_DURATION_MS) {
        platform.time.sleepMs(@intCast(interval_ms));
        elapsed_ms += interval_ms;

        if (elapsed_ms - last_report_ms >= METRIC_INTERVAL_MS) {
            last_report_ms = elapsed_ms;
            printMetrics(&metrics, elapsed_ms);
        }
    }

    // ========================================================================
    // Shutdown
    // ========================================================================

    log.info("Test duration reached. Shutting down...", .{});
    cancel.cancel();
    ch.close();
    wg.wait();

    // Final metrics
    log.info("==========================================", .{});
    log.info("FINAL REPORT", .{});
    log.info("==========================================", .{});
    printMetrics(&metrics, elapsed_ms);

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
