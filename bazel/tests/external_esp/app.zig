//! Opus Test — External Repo (simulates giztoy chatgear dep set)
//!
//! Tests opus encoder/decoder init and a single encode/decode cycle,
//! with the same dependency set as giztoy chatgear (channel, waitgroup,
//! cancellation). If this crashes with InstrFetchProhibited, the external
//! repo cross-compilation is broken.
//!
//! The extra deps exercise module-count-sensitive code paths in the
//! Zig compiler (e.g., @cImport resolution with many -M modules).

const std = @import("std");
const idf = @import("idf");
const opus = @import("opus");

// Import extra deps to match giztoy chatgear's module set.
// Even if unused, they affect the build.zig module graph and
// potentially the @cImport resolution order.
const Channel = @import("channel").Channel;
const WaitGroup = @import("waitgroup").WaitGroup;
const CancellationToken = @import("cancellation").CancellationToken;

const heap = idf.heap;
const log = std.log.scoped(.opus_test);

const SAMPLE_RATE: u32 = 16000;
const CHANNELS: u8 = 1;
const FRAME_MS: u32 = 20;
const FRAME_SAMPLES: usize = SAMPLE_RATE * FRAME_MS / 1000; // 320

pub fn run(_: anytype) void {
    log.info("=== Opus External Repo Test (extended deps) ===", .{});

    // Verify extra deps are resolvable (compile-time check)
    log.info("Channel size: {}, WaitGroup size: {}, CancellationToken size: {}", .{
        @sizeOf(Channel([]const u8, 1)),
        @sizeOf(WaitGroup(struct {
            pub const Mutex = std.Thread.Mutex;
            pub const Condition = std.Thread.Mutex.Condition;
            pub fn spawn(_: anytype, _: anytype, _: anytype) !void {}
        })),
        @sizeOf(CancellationToken),
    });

    // 1. Print opus version
    log.info("Opus version: {s}", .{opus.getVersionString()});

    // 2. Init encoder (this is where the crash happens)
    log.info("Initializing encoder...", .{});
    var encoder = opus.Encoder.init(
        heap.psram,
        SAMPLE_RATE,
        CHANNELS,
        .voip,
    ) catch |e| {
        log.err("Encoder init failed: {}", .{e});
        return;
    };
    defer encoder.deinit(heap.psram);
    log.info("Encoder init OK (size={})", .{opus.Encoder.getSize(CHANNELS)});

    // 3. Init decoder
    log.info("Initializing decoder...", .{});
    var decoder = opus.Decoder.init(
        heap.psram,
        SAMPLE_RATE,
        CHANNELS,
    ) catch |e| {
        log.err("Decoder init failed: {}", .{e});
        return;
    };
    defer decoder.deinit(heap.psram);
    log.info("Decoder init OK", .{});

    // 4. Encode a frame of silence
    var pcm_in: [FRAME_SAMPLES]i16 = [_]i16{0} ** FRAME_SAMPLES;
    var opus_buf: [512]u8 = undefined;
    const encoded = encoder.encode(&pcm_in, FRAME_SAMPLES, &opus_buf) catch |e| {
        log.err("Encode failed: {}", .{e});
        return;
    };
    log.info("Encoded {} bytes", .{encoded.len});

    // 5. Decode it back
    var pcm_out: [FRAME_SAMPLES]i16 = undefined;
    const decoded = decoder.decode(encoded, &pcm_out, false) catch |e| {
        log.err("Decode failed: {}", .{e});
        return;
    };
    log.info("Decoded {} samples", .{decoded.len});

    // 6. Success!
    log.info("=== Opus External Repo Test PASSED ===", .{});
}
