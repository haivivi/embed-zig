//! AEC Loopback Test — Mic → AEC → Speaker (real-time)

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE = 8000;
const FRAME_SIZE = 160; // 20ms @ 8kHz

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  AEC Loopback: Mic -> AEC -> Speaker", .{});
    log.info("==========================================", .{});

    const armino = @import("bk").armino;

    log.info("Init speaker...", .{});
    var speaker = armino.speaker.Speaker.init(SAMPLE_RATE, 1, 16, 0x2D) catch |err| {
        log.err("Speaker init failed: {}", .{err});
        return;
    };
    defer speaker.deinit();
    log.info("Speaker OK", .{});

    log.info("Init mic...", .{});
    var mic = armino.mic.Mic.init(SAMPLE_RATE, 1, 0x2d, 0x08) catch |err| {
        log.err("Mic init failed: {}", .{err});
        return;
    };
    defer mic.deinit();
    log.info("Mic OK", .{});

    log.info("Init AEC (v3)...", .{});
    var aec = armino.aec.Aec.init(1000, SAMPLE_RATE) catch |err| {
        log.err("AEC init failed: {} — fallback to raw loopback", .{err});
        var buf: [FRAME_SIZE]i16 = undefined;
        var fc: u32 = 0;
        while (Board.isRunning()) {
            const n = mic.read(&buf) catch continue;
            if (n > 0) _ = speaker.write(buf[0..n]) catch {};
            fc += 1;
            if (fc % 250 == 0) log.info("[no-aec {}s] frames={}", .{ fc / 50, fc });
        }
        return;
    };
    defer aec.deinit();

    const aec_frame = aec.getFrameSamples();
    log.info("AEC OK, frame={} ({}ms)", .{ aec_frame, aec_frame * 1000 / SAMPLE_RATE });

    var mic_buf: [FRAME_SIZE]i16 = undefined;
    var ref_buf: [FRAME_SIZE]i16 = @splat(0);
    var out_buf: [FRAME_SIZE]i16 = undefined;
    var frame_count: u32 = 0;

    while (Board.isRunning()) {
        const to_read = @min(FRAME_SIZE, aec_frame);
        const n = mic.read(mic_buf[0..to_read]) catch continue;
        if (n == 0) continue;

        aec.process(ref_buf[0..n], mic_buf[0..n], out_buf[0..n]);

        const written = speaker.write(out_buf[0..n]) catch 0;
        if (written > 0) @memcpy(ref_buf[0..written], out_buf[0..written]);

        frame_count += 1;
        if (frame_count % 250 == 0) {
            log.info("[{}s] frames={}", .{ frame_count / 50, frame_count });
        }
    }
}
