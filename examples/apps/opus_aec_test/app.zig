//! Opus AEC Loopback Test — Multi-task Pipeline
//!
//! Pipeline: mic → AEC → [Channel] → opus encode → decode → speaker
//!
//! Task 1 (mic_task):   readMic → gain → accumulate frame → channel.send
//! Task 2 (codec_task): channel.recv → encode → decode → writeSpeaker
//!
//! I/O never blocked by encode. Channel absorbs timing jitter.

const std = @import("std");
const idf = @import("idf");
const opus = @import("opus");
const channel_mod = @import("channel");
const waitgroup = @import("waitgroup");
const cancellation = @import("cancellation");

const heap = idf.heap;
const EspRt = idf.runtime;

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
const PCM_FRAME_BYTES: usize = FRAME_SAMPLES * 2;
const MAX_OPUS: usize = 512;
const BITRATE: u32 = 24000;
const COMPLEXITY: u4 = 0;
const MIC_GAIN: i32 = 8;
const SPEAKER_VOL: u8 = 150;
const TEST_DURATION_MS: u64 = 30_000;
const METRIC_INTERVAL_MS: u64 = 5_000;
const CH_DEPTH: usize = 4;

// ============================================================================
// Types
// ============================================================================

const PcmFrame = [FRAME_SAMPLES]i16;
const PcmCh = channel_mod.Channel(PcmFrame, CH_DEPTH, EspRt);
const WG = waitgroup.WaitGroup(EspRt);
const Cancel = cancellation.CancellationToken;

const Metrics = struct {
    frames: u64 = 0,
    pcm_bytes: u64 = 0,
    opus_bytes: u64 = 0,
    enc_us: u64 = 0,
    dec_us: u64 = 0,
    drops: u64 = 0,
};

// ============================================================================
// Mic Task — read AEC mic, gain, accumulate, send PCM frame to channel
// ============================================================================

const MicCtx = struct {
    board: *Board,
    ch: *PcmCh,
    cancel: *Cancel,
    drops: *u64,
};

fn micTask(ctx: *MicCtx) void {
    log.info("[mic] task started", .{});

    var buf: [FRAME_SAMPLES]i16 = undefined;
    var accum: PcmFrame = undefined;
    var accum_n: usize = 0;
    var frame_count: u32 = 0;

    while (!ctx.cancel.isCancelled()) {
        const n_read = ctx.board.audio.readMic(&buf) catch {
            platform.time.sleepMs(10);
            continue;
        };
        if (n_read == 0) {
            platform.time.sleepMs(1);
            continue;
        }

        // Gain
        for (0..n_read) |i| {
            const v: i32 = @as(i32, buf[i]) * MIC_GAIN;
            buf[i] = @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
        }

        // Accumulate to frame boundary
        var pos: usize = 0;
        while (pos < n_read) {
            const n = @min(n_read - pos, FRAME_SAMPLES - accum_n);
            @memcpy(accum[accum_n..][0..n], buf[pos..][0..n]);
            accum_n += n;
            pos += n;

            if (accum_n == FRAME_SAMPLES) {
                ctx.ch.trySend(accum) catch |err| switch (err) {
                    error.Full => {
                        ctx.drops.* += 1;
                        accum_n = 0;
                        continue;
                    },
                    error.Closed => return,
                };
                accum_n = 0;
                frame_count += 1;
                if (frame_count % 250 == 1) {
                    log.info("[mic] frames={}", .{frame_count});
                }
            }
        }
    }
    log.info("[mic] task exit", .{});
}

// ============================================================================
// Codec Task — recv PCM, encode, decode, write speaker
// ============================================================================

const CodecCtx = struct {
    board: *Board,
    ch: *PcmCh,
    cancel: *Cancel,
    metrics: *Metrics,
    encoder: *opus.Encoder,
    decoder: *opus.Decoder,
};

fn codecTask(ctx: *CodecCtx) void {
    log.info("[codec] task started", .{});

    var opus_buf: [MAX_OPUS]u8 = undefined;
    var dec_buf: [FRAME_SAMPLES]i16 = undefined;

    while (!ctx.cancel.isCancelled()) {
        const pcm = ctx.ch.recv() orelse break;

        // Encode
        const t0 = idf.time.nowUs();
        const encoded = ctx.encoder.encode(&pcm, FRAME_SAMPLES, &opus_buf) catch |err| {
            log.err("[codec] enc: {}", .{err});
            continue;
        };
        const t1 = idf.time.nowUs();

        // Decode
        const decoded = ctx.decoder.decode(encoded, &dec_buf, false) catch |err| {
            log.err("[codec] dec: {}", .{err});
            continue;
        };
        const t2 = idf.time.nowUs();

        // Speaker
        if (decoded.len > 0) {
            _ = ctx.board.audio.writeSpeaker(decoded) catch |err| {
                log.err("[codec] spk: {}", .{err});
                continue;
            };
        }

        ctx.metrics.frames += 1;
        ctx.metrics.pcm_bytes += PCM_FRAME_BYTES;
        ctx.metrics.opus_bytes += encoded.len;
        ctx.metrics.enc_us += (t1 - t0);
        ctx.metrics.dec_us += (t2 - t1);

        if (ctx.metrics.frames % 250 == 1) {
            log.info("[codec] frames={} enc={}us", .{ ctx.metrics.frames, (t1 - t0) });
        }
    }
    log.info("[codec] task exit", .{});
}

// ============================================================================
// Entry
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Opus AEC Loopback — Multi-task Pipeline", .{});
    log.info("==========================================", .{});
    log.info("Board:   {s}", .{platform.Hardware.name});
    log.info("Rate:    {}Hz  Frame: {}ms  Bitrate: {}bps  C: {}", .{ SAMPLE_RATE, FRAME_MS, BITRATE, COMPLEXITY });
    log.info("Enc: {}B  Dec: {}B  Ch depth: {}", .{ opus.Encoder.getSize(CHANNELS), opus.Decoder.getSize(CHANNELS), CH_DEPTH });
    log.info("==========================================", .{});

    // Board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("board: {}", .{err});
        return;
    };
    defer board.deinit();
    board.pa_switch.on() catch |err| {
        log.err("PA: {}", .{err});
        return;
    };
    defer board.pa_switch.off() catch {};
    board.audio.setVolume(SPEAKER_VOL);

    // Heap before
    const h0 = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const p0 = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] before: int={}KB ps={}KB", .{ h0 / 1024, p0 / 1024 });

    // Opus on PSRAM
    const alloc = heap.psram;
    var encoder = opus.Encoder.init(alloc, SAMPLE_RATE, CHANNELS, .voip) catch |err| {
        log.err("enc init: {}", .{err});
        return;
    };
    defer encoder.deinit(alloc);
    encoder.setBitrate(BITRATE) catch {};
    encoder.setComplexity(COMPLEXITY) catch {};
    encoder.setSignal(.voice) catch {};

    var decoder = opus.Decoder.init(alloc, SAMPLE_RATE, CHANNELS) catch |err| {
        log.err("dec init: {}", .{err});
        return;
    };
    defer decoder.deinit(alloc);

    const h1 = heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL);
    const p1 = heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM);
    log.info("[heap] after:  int={}KB ps={}KB  opus: int={}KB ps={}KB", .{
        h1 / 1024, p1 / 1024, (h0 -| h1) / 1024, (p0 -| p1) / 1024,
    });

    // Channel + sync — heap-allocated to ensure stable addresses for tasks
    const ch = alloc.create(PcmCh) catch |err| {
        log.err("ch alloc: {}", .{err});
        return;
    };
    defer alloc.destroy(ch);
    ch.* = PcmCh.init();
    defer ch.deinit();

    var cancel = Cancel.init();

    const metrics = alloc.create(Metrics) catch |err| {
        log.err("metrics alloc: {}", .{err});
        return;
    };
    defer alloc.destroy(metrics);
    metrics.* = Metrics{};

    // Spawn tasks
    var wg = WG.init();
    defer wg.deinit();

    const mic_ctx = alloc.create(MicCtx) catch |err| {
        log.err("mic_ctx alloc: {}", .{err});
        return;
    };
    defer alloc.destroy(mic_ctx);
    mic_ctx.* = MicCtx{ .board = &board, .ch = ch, .cancel = &cancel, .drops = &metrics.drops };

    const codec_ctx = alloc.create(CodecCtx) catch |err| {
        log.err("codec_ctx alloc: {}", .{err});
        return;
    };
    defer alloc.destroy(codec_ctx);
    codec_ctx.* = CodecCtx{
        .board = &board, .ch = ch, .cancel = &cancel, .metrics = metrics,
        .encoder = &encoder, .decoder = &decoder,
    };

    wg.goWithConfig(.{ .stack_size = 49152 }, micTask, .{mic_ctx}) catch |err| {
        log.err("mic spawn: {}", .{err});
        return;
    };

    platform.time.sleepMs(50);

    wg.goWithConfig(.{ .stack_size = 49152 }, codecTask, .{codec_ctx}) catch |err| {
        log.err("codec spawn: {}", .{err});
        return;
    };

    log.info("Pipeline running {}s — speak into mic", .{TEST_DURATION_MS / 1000});

    // Report loop
    var t_last: u64 = 0;
    const t0_ms = idf.time.nowMs();
    while (idf.time.nowMs() - t0_ms < TEST_DURATION_MS) {
        platform.time.sleepMs(100);
        const elapsed = idf.time.nowMs() - t0_ms;
        if (elapsed - t_last >= METRIC_INTERVAL_MS) {
            t_last = elapsed;
            report(metrics, elapsed);
        }
    }

    // Shutdown
    cancel.cancel();
    ch.close();
    wg.wait();

    log.info("==========================================", .{});
    log.info("FINAL", .{});
    report(metrics, TEST_DURATION_MS);
    log.info("[heap] final: int={}KB ps={}KB min_int={}KB", .{
        heap.heap_caps_get_free_size(heap.MALLOC_CAP_INTERNAL) / 1024,
        heap.heap_caps_get_free_size(heap.MALLOC_CAP_SPIRAM) / 1024,
        heap.heap_caps_get_minimum_free_size(heap.MALLOC_CAP_INTERNAL) / 1024,
    });
    log.info("==========================================", .{});

    while (true) {
        platform.time.sleepMs(5000);
    }
}

fn report(m: *const Metrics, ms: u64) void {
    const enc = if (m.frames > 0) m.enc_us / m.frames else 0;
    const dec = if (m.frames > 0) m.dec_us / m.frames else 0;
    const ratio = if (m.opus_bytes > 0) m.pcm_bytes / m.opus_bytes else 0;
    log.info("[{}s] frames={} enc={}us dec={}us ratio={}:1 drops={}", .{
        ms / 1000, m.frames, enc, dec, ratio, m.drops,
    });
}
