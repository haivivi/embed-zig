//! mic_test — Record clean mic for 5s, beep twice, then playback

const std = @import("std");
const audio = @import("audio");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const RECORD_SECONDS: u32 = 5;

const EngineType = audio.engine.AudioEngine(
    Board.runtime,
    Board.DuplexAudio.Mic,
    Board.DuplexAudio.Speaker,
    .{
        .enable_aec = false,
        .enable_ns = false,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .RefReader = Board.DuplexAudio.RefReader,
    },
);

pub fn run(_: anytype) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    Board.initAudio() catch |err| {
        log.err("[mic_test] Audio init failed: {}", .{err});
        return;
    };
    defer Board.deinitAudio();

    log.info("[mic_test] ==========================================", .{});
    log.info("[mic_test] Record clean mic 5s -> beep x2 -> playback", .{});
    log.info("[mic_test] ==========================================", .{});

    var duplex = Board.DuplexAudio.init(allocator) catch |err| {
        log.err("[mic_test] Duplex init failed: {}", .{err});
        return;
    };
    defer duplex.stop();

    duplex.start() catch |err| {
        log.err("[mic_test] Duplex start failed: {}", .{err});
        return;
    };

    var mic = duplex.mic();
    var spk = duplex.speaker();
    var ref = duplex.refReader();

    var engine = EngineType.init(allocator, &mic, &spk, &ref) catch |err| {
        log.err("[mic_test] Engine init failed: {}", .{err});
        return;
    };
    defer engine.deinit();

    engine.start() catch |err| {
        log.err("[mic_test] Engine start failed: {}", .{err});
        return;
    };

    // 1) Record clean for 5 seconds into memory
    const total_samples: usize = RECORD_SECONDS * SAMPLE_RATE;
    const clean_buf = allocator.alloc(i16, total_samples) catch |err| {
        log.err("[mic_test] alloc clean buffer failed: {}", .{err});
        return;
    };
    defer allocator.free(clean_buf);

    log.info("[mic_test] recording {}s...", .{RECORD_SECONDS});
    var pos: usize = 0;
    while (pos < clean_buf.len) {
        var frame: [FRAME_SIZE]i16 = undefined;
        const n = engine.readClean(&frame) orelse break;
        const to_copy = @min(n, clean_buf.len - pos);
        @memcpy(clean_buf[pos .. pos + to_copy], frame[0..to_copy]);
        pos += to_copy;
    }
    if (pos < clean_buf.len) @memset(clean_buf[pos..], 0);

    // 2) Beep beep
    const fmt = audio.Format{ .rate = SAMPLE_RATE, .channels = .mono };
    const beep_track = engine.createTrack(.{ .label = "beep" }) catch |err| {
        log.err("[mic_test] create beep track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(beep_track.ctrl);

    const beep = synthBeep(allocator, 1000.0, 180) catch |err| {
        log.err("[mic_test] synth beep failed: {}", .{err});
        return;
    };
    defer allocator.free(beep);

    const gap = allocator.alloc(i16, SAMPLE_RATE / 8) catch |err| {
        log.err("[mic_test] alloc gap failed: {}", .{err});
        return;
    };
    defer allocator.free(gap);
    @memset(gap, 0);

    _ = beep_track.track.write(fmt, beep) catch {};
    _ = beep_track.track.write(fmt, gap) catch {};
    _ = beep_track.track.write(fmt, beep) catch {};

    // 3) Playback recorded clean buffer
    const playback_track = engine.createTrack(.{ .label = "playback" }) catch |err| {
        log.err("[mic_test] create playback track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(playback_track.ctrl);
    _ = playback_track.track.write(fmt, clean_buf) catch |err| {
        log.err("[mic_test] write playback failed: {}", .{err});
        return;
    };

    // Wait until playback finishes
    Board.time.sleepMs(1200 + RECORD_SECONDS * 1000);
    log.info("[mic_test] done", .{});
}

fn synthBeep(allocator: std.mem.Allocator, freq: f32, ms: u32) ![]i16 {
    const n: usize = @intCast((SAMPLE_RATE * ms) / 1000);
    const out = try allocator.alloc(i16, n);
    for (0..n) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(SAMPLE_RATE));
        const x = @sin(2.0 * std.math.pi * freq * t) * 14000.0;
        out[i] = @intFromFloat(std.math.clamp(x, -32767.0, 32767.0));
    }
    return out;
}

pub fn main() !void {
    run(.{});
}
