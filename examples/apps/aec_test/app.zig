//! AEC Test — AudioSystem loopback test
//!
//! 1. Plays a startup beep (confirms speaker works)
//! 2. Then does mic → AEC → speaker loopback (speak into mic, hear yourself)

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE = 8000;
const AMPLITUDE: i16 = 12000;

// Comptime sine table
const sine_table = blk: {
    var table: [256]i16 = undefined;
    for (0..256) |i| {
        const angle = @as(f64, @floatFromInt(i)) * 2.0 * std.math.pi / 256.0;
        table[i] = @intFromFloat(@sin(angle) * 32767.0);
    }
    break :blk table;
};

fn generateTone(buffer: []i16, frequency: u32, phase: *u32) void {
    const phase_inc: u32 = frequency * 65536 / SAMPLE_RATE;
    for (buffer) |*sample| {
        const idx: u8 = @truncate(phase.* >> 8);
        const sin_val = sine_table[idx];
        sample.* = @intCast(@divTrunc(@as(i32, sin_val) * @as(i32, AMPLITUDE), 32767));
        phase.* +%= phase_inc;
    }
}

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  AEC Test — Mic Loopback", .{});
    log.info("  Board: {s}", .{Board.meta.id});
    log.info("==========================================", .{});

    // Init speaker + mic separately (no AEC for now — test basic loopback)
    const armino = @import("bk").armino;

    log.info("Init mic...", .{});
    var mic = armino.mic.Mic.init(SAMPLE_RATE, 1, 0x2d) catch |err| {
        log.err("Mic init failed: {}", .{err});
        return;
    };
    defer mic.deinit();

    log.info("Init speaker...", .{});
    var speaker = armino.speaker.Speaker.init(SAMPLE_RATE, 1, 16, 0x3F) catch |err| {
        log.err("Speaker init failed: {}", .{err});
        return;
    };
    defer speaker.deinit();

    // Play startup beep
    log.info("Playing beep...", .{});
    {
        var buffer: [160]i16 = undefined;
        var phase: u32 = 0;
        const beep_frames = SAMPLE_RATE * 300 / 1000 / 160;
        for (0..beep_frames) |_| {
            generateTone(&buffer, 500, &phase);
            _ = speaker.write(&buffer) catch {};
        }
        @memset(&buffer, 0);
        for (0..5) |_| {
            _ = speaker.write(&buffer) catch {};
        }
    }

    log.info("Mic loopback started — speak into the mic!", .{});

    // Simple mic → speaker loopback (no AEC)
    var mic_buffer: [160]i16 = undefined;
    var frame_count: u32 = 0;

    while (true) {
        const samples_read = mic.read(&mic_buffer) catch {
            Board.time.sleepMs(10);
            continue;
        };

        if (samples_read > 0) {
            _ = speaker.write(mic_buffer[0..samples_read]) catch {};
        }

        frame_count += 1;
        if (frame_count % 500 == 0) {
            log.info("[MIC] {} frames", .{frame_count});
        }
    }
}
