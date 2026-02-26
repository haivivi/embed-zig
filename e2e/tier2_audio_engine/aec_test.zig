//! aec_test — AEC verification: play Für Elise (far-end) while recording clean mic
//!
//! Three concurrent tasks, each generates exactly RECORD_SECONDS of PCM then exits:
//!   task1 (recorder):  engine.readClean() -> buffer  (5s)
//!   task2 (melody):    Für Elise melody -> track     (5s)
//!   task3 (bass):      Für Elise bass   -> track     (5s)
//!
//! After all tasks finish naturally:
//!   beep beep -> playback recorded clean buffer
//!
//! If AEC works, the clean recording should contain mostly near-end
//! (real mic) and very little of the far-end Für Elise.

const std = @import("std");
const audio = @import("audio");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const RECORD_SECONDS: u32 = 5;
const TEMPO: f32 = 120.0;

const EngineType = audio.engine.AudioEngine(
    Board.runtime,
    Board.DuplexAudio.Mic,
    Board.DuplexAudio.Speaker,
    .{
        .enable_aec = true,
        .enable_ns = true,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .aec_filter_length = 16000,
        .RefReader = Board.DuplexAudio.RefReader,
    },
);

// ================================================================
// Für Elise notes (same as speaker_test.zig)
// ================================================================

const Note = struct { freq: f32, beats: f32 };

const MELODY = &[_]Note{
    .{ .freq = 659.25, .beats = 0.25 }, .{ .freq = 622.25, .beats = 0.25 },
    .{ .freq = 659.25, .beats = 0.25 }, .{ .freq = 622.25, .beats = 0.25 },
    .{ .freq = 659.25, .beats = 0.25 }, .{ .freq = 493.88, .beats = 0.25 },
    .{ .freq = 587.33, .beats = 0.25 }, .{ .freq = 523.25, .beats = 0.25 },
    .{ .freq = 440.00, .beats = 0.50 }, .{ .freq = 329.63, .beats = 0.25 },
    .{ .freq = 440.00, .beats = 0.25 }, .{ .freq = 523.25, .beats = 0.50 },
    .{ .freq = 329.63, .beats = 0.25 }, .{ .freq = 440.00, .beats = 0.25 },
};

const BASS = &[_]Note{
    .{ .freq = 220.00, .beats = 0.5 }, .{ .freq = 164.81, .beats = 0.5 },
    .{ .freq = 220.00, .beats = 0.5 }, .{ .freq = 164.81, .beats = 0.5 },
    .{ .freq = 220.00, .beats = 0.5 }, .{ .freq = 261.63, .beats = 0.5 },
    .{ .freq = 220.00, .beats = 0.5 }, .{ .freq = 164.81, .beats = 0.5 },
};

// ================================================================
// Task contexts
// ================================================================

const RecorderCtx = struct {
    engine: *EngineType,
    clean_buf: []i16,
    recorded: usize,
};

const FarEndCtx = struct {
    handle: EngineType.TrackHandle,
    notes: []const Note,
    amp: f32,
    total_samples: usize, // how many samples to generate
    written: usize, // how many samples actually written
};

fn recorderTask(ctx: *RecorderCtx) void {
    var frame: [FRAME_SIZE]i16 = undefined;

    while (ctx.recorded < ctx.clean_buf.len) {
        const n = ctx.engine.readClean(&frame) orelse break;
        if (n == 0) continue;

        const to_copy = @min(n, ctx.clean_buf.len - ctx.recorded);
        @memcpy(ctx.clean_buf[ctx.recorded .. ctx.recorded + to_copy], frame[0..to_copy]);
        ctx.recorded += to_copy;
    }
}

fn farEndTask(ctx: *FarEndCtx) void {
    const sec_per_beat = 60.0 / TEMPO;
    const fmt = audio.Format{ .rate = SAMPLE_RATE, .channels = .mono };
    var frame: [FRAME_SIZE]i16 = undefined;

    while (ctx.written < ctx.total_samples) {
        for (ctx.notes) |note| {
            if (ctx.written >= ctx.total_samples) return;

            const note_len: usize = @intFromFloat(note.beats * sec_per_beat * @as(f32, @floatFromInt(SAMPLE_RATE)));
            var i: usize = 0;
            while (i < note_len) {
                if (ctx.written >= ctx.total_samples) return;

                const n = @min(FRAME_SIZE, note_len - i);
                for (0..n) |j| {
                    const t = @as(f32, @floatFromInt(i + j)) / @as(f32, @floatFromInt(SAMPLE_RATE));
                    const f = note.freq;
                    const h1 = @sin(t * f * 2.0 * std.math.pi);
                    const h2 = 0.4 * @sin(t * f * 4.0 * std.math.pi);
                    const h3 = 0.2 * @sin(t * f * 6.0 * std.math.pi);

                    const attack = @min(1.0, @as(f32, @floatFromInt(i + j)) / 800.0);
                    const release = @max(0.0, 1.0 - @as(f32, @floatFromInt((i + j) -| note_len +| 1500)) / 2000.0);
                    const env = attack * release;

                    const s = (h1 + h2 + h3) * env * ctx.amp * 15000.0;
                    frame[j] = @intFromFloat(std.math.clamp(s, -32767.0, 32767.0));
                }
                ctx.handle.track.write(fmt, frame[0..n]) catch return;
                ctx.written += n;
                i += n;
            }
        }
    }
}

// ================================================================
// Main
// ================================================================

pub fn run(_: anytype) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    Board.initAudio() catch |err| {
        log.err("[aec_test] Audio init failed: {}", .{err});
        return;
    };
    defer Board.deinitAudio();

    log.info("[aec_test] ==========================================", .{});
    log.info("[aec_test] AEC: Für Elise far-end + mic record 5s", .{});
    log.info("[aec_test] ==========================================", .{});

    var duplex = Board.DuplexAudio.init(allocator) catch |err| {
        log.err("[aec_test] Duplex init failed: {}", .{err});
        return;
    };
    defer duplex.stop();

    duplex.start() catch |err| {
        log.err("[aec_test] Duplex start failed: {}", .{err});
        return;
    };

    var mic_dev = duplex.mic();
    var spk_dev = duplex.speaker();
    var ref_dev = duplex.refReader();

    var engine = EngineType.init(allocator, &mic_dev, &spk_dev, &ref_dev) catch |err| {
        log.err("[aec_test] Engine init failed: {}", .{err});
        return;
    };
    defer engine.deinit();

    const melody_track = engine.createTrack(.{ .label = "melody" }) catch |err| {
        log.err("[aec_test] create melody track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(melody_track.ctrl);

    const bass_track = engine.createTrack(.{ .label = "bass" }) catch |err| {
        log.err("[aec_test] create bass track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(bass_track.ctrl);

    engine.start() catch |err| {
        log.err("[aec_test] Engine start failed: {}", .{err});
        return;
    };

    // Allocate clean recording buffer
    const total_samples: usize = RECORD_SECONDS * SAMPLE_RATE;
    const clean_buf = allocator.alloc(i16, total_samples) catch |err| {
        log.err("[aec_test] alloc clean buffer failed: {}", .{err});
        return;
    };
    defer allocator.free(clean_buf);

    // Start all three tasks — each generates exactly 5s then exits
    var rec_ctx = RecorderCtx{
        .engine = &engine,
        .clean_buf = clean_buf,
        .recorded = 0,
    };
    var melody_ctx = FarEndCtx{
        .handle = melody_track,
        .notes = MELODY,
        .amp = 0.8,
        .total_samples = total_samples,
        .written = 0,
    };
    var bass_ctx = FarEndCtx{
        .handle = bass_track,
        .notes = BASS,
        .amp = 0.6,
        .total_samples = total_samples,
        .written = 0,
    };

    const t_rec = Board.runtime.Thread.spawn(.{}, recorderTask, .{&rec_ctx}) catch |err| {
        log.err("[aec_test] spawn recorder task failed: {}", .{err});
        return;
    };
    const t_melody = Board.runtime.Thread.spawn(.{}, farEndTask, .{&melody_ctx}) catch |err| {
        log.err("[aec_test] spawn melody task failed: {}", .{err});
        t_rec.join();
        return;
    };
    const t_bass = Board.runtime.Thread.spawn(.{}, farEndTask, .{&bass_ctx}) catch |err| {
        log.err("[aec_test] spawn bass task failed: {}", .{err});
        t_melody.join();
        t_rec.join();
        return;
    };

    log.info("[aec_test] recording {}s with Für Elise playing...", .{RECORD_SECONDS});

    // All tasks exit naturally after generating 5s of PCM
    t_melody.join();
    t_bass.join();
    t_rec.join();

    const recorded = rec_ctx.recorded;
    if (recorded < total_samples) @memset(clean_buf[recorded..], 0);

    log.info("[aec_test] far-end melody: {} samples ({d:.1}s)", .{ melody_ctx.written, @as(f32, @floatFromInt(melody_ctx.written)) / @as(f32, @floatFromInt(SAMPLE_RATE)) });
    log.info("[aec_test] far-end bass:   {} samples ({d:.1}s)", .{ bass_ctx.written, @as(f32, @floatFromInt(bass_ctx.written)) / @as(f32, @floatFromInt(SAMPLE_RATE)) });
    log.info("[aec_test] clean recorded: {} samples ({d:.1}s)", .{ recorded, @as(f32, @floatFromInt(recorded)) / @as(f32, @floatFromInt(SAMPLE_RATE)) });

    // ---- Phase 2: playback (engine still running) ----
    const fmt = audio.Format{ .rate = SAMPLE_RATE, .channels = .mono };

    // Beep beep
    const beep_track = engine.createTrack(.{ .label = "beep" }) catch |err| {
        log.err("[aec_test] create beep track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(beep_track.ctrl);

    const beep = synthBeep(allocator, 1000.0, 180) catch |err| {
        log.err("[aec_test] synth beep failed: {}", .{err});
        return;
    };
    defer allocator.free(beep);

    const gap = allocator.alloc(i16, SAMPLE_RATE / 8) catch |err| {
        log.err("[aec_test] alloc gap failed: {}", .{err});
        return;
    };
    defer allocator.free(gap);
    @memset(gap, 0);

    log.info("[aec_test] beep beep...", .{});
    _ = beep_track.track.write(fmt, beep) catch {};
    _ = beep_track.track.write(fmt, gap) catch {};
    _ = beep_track.track.write(fmt, beep) catch {};
    _ = beep_track.track.write(fmt, gap) catch {};

    // Playback recorded clean
    log.info("[aec_test] playing back clean recording...", .{});
    const playback_track = engine.createTrack(.{ .label = "playback" }) catch |err| {
        log.err("[aec_test] create playback track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(playback_track.ctrl);
    _ = playback_track.track.write(fmt, clean_buf[0..recorded]) catch |err| {
        log.err("[aec_test] write playback failed: {}", .{err});
        return;
    };

    // Wait for playback to finish
    const playback_ms: u32 = @intCast((recorded * 1000) / SAMPLE_RATE + 1500);
    Board.time.sleepMs(playback_ms);

    log.info("[aec_test] done", .{});
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
