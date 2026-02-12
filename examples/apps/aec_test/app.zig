//! Mic -> Speaker Loopback
//!
//! Real-time loopback: reads mic, writes to speaker.
//! Speak near the board and hear yourself.
//!
//! AEC is disabled — libaec.a crashes on aec_init (TrustZone/link issue TBD).

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE = 8000;
const FRAME_SIZE = 160; // 20ms @ 8kHz

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  Mic -> Speaker Loopback", .{});
    log.info("==========================================", .{});

    const armino = @import("bk").armino;

    // Init speaker
    log.info("Init speaker...", .{});
    var speaker = armino.speaker.Speaker.init(SAMPLE_RATE, 1, 16, 0x2D) catch |err| {
        log.err("Speaker init failed: {}", .{err});
        return;
    };
    defer speaker.deinit();
    log.info("Speaker OK", .{});

    // Init mic
    log.info("Init mic...", .{});
    var mic = armino.mic.Mic.init(SAMPLE_RATE, 1, 0x2d, 0x08) catch |err| {
        log.err("Mic init failed: {}", .{err});
        return;
    };
    defer mic.deinit();
    log.info("Mic OK", .{});

    log.info("Loopback running! Speak near the board.", .{});

    var buf: [FRAME_SIZE]i16 = undefined;
    var frame_count: u32 = 0;

    while (Board.isRunning()) {
        const n = mic.read(&buf) catch continue;
        if (n == 0) continue;

        _ = speaker.write(buf[0..n]) catch {};

        frame_count += 1;
        if (frame_count % 250 == 0) {
            log.info("[{}s] frames={}", .{ frame_count / 50, frame_count });
        }
    }
}
