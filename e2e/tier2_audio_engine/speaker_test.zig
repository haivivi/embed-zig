//! tier2_audio_engine app — speaker test using two streaming tasks
//!
//! Mirrors tier1 style: app logic here, platform in platform.zig, board impl in std/.

const std = @import("std");

const audio = @import("audio");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = Board.engine_frame_size;
const FRAME_LEN: usize = FRAME_SIZE;
const TEMPO: f32 = 120.0;
const PLAY_DURATION_MS: u64 = 10_000;

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
        .Processor = if (@hasDecl(Board, "Processor")) Board.Processor else null,
    },
);

const TrackCtx = struct {
    handle: EngineType.TrackHandle,
    notes: []const Note,
    amp: f32,
    deadline_ms: u64,
    name: []const u8,
};

fn writerTask(ctx: *TrackCtx) void {
    const sec_per_beat = 60.0 / TEMPO;
    const fmt = audio.Format{ .rate = SAMPLE_RATE, .channels = .mono };
    var frame: [FRAME_LEN]i16 = undefined;

    while (Board.time.nowMs() < ctx.deadline_ms) {
        for (ctx.notes) |note| {
            if (Board.time.nowMs() >= ctx.deadline_ms) break;
            const note_len: usize = @intFromFloat(note.beats * sec_per_beat * @as(f32, @floatFromInt(SAMPLE_RATE)));
            var i: usize = 0;
            while (i < note_len) {
                if (Board.time.nowMs() >= ctx.deadline_ms) break;
                const n = @min(FRAME_LEN, note_len - i);
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
                ctx.handle.track.write(fmt, frame[0..n]) catch break;
                i += n;
            }
        }
    }
}

pub fn run(_: anytype) void {
    const allocator = Board.allocator();

    Board.initAudio() catch |err| {
        log.err("[speaker_test] Audio init failed: {}", .{err});
        return;
    };
    defer Board.deinitAudio();

    log.info("[speaker_test] ==========================================", .{});
    log.info("[speaker_test] AudioEngine two-track Für Elise", .{});
    log.info("[speaker_test] ==========================================", .{});

    var duplex = Board.DuplexAudio.init(allocator) catch |err| {
        log.err("[speaker_test] Duplex init failed: {}", .{err});
        return;
    };
    defer duplex.stop();

    duplex.start() catch |err| {
        log.err("[speaker_test] Duplex start failed: {}", .{err});
        return;
    };

    var mic = duplex.mic();
    var spk = duplex.speaker();
    var ref = duplex.refReader();

    var engine = EngineType.init(allocator, &mic, &spk, &ref) catch |err| {
        log.err("[speaker_test] Engine init failed: {}", .{err});
        return;
    };
    defer engine.deinit();

    const melody = engine.createTrack(.{ .label = "melody" }) catch |err| {
        log.err("[speaker_test] create melody track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(melody.ctrl);

    const bass = engine.createTrack(.{ .label = "bass" }) catch |err| {
        log.err("[speaker_test] create bass track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(bass.ctrl);

    engine.start() catch |err| {
        log.err("[speaker_test] Engine start failed: {}", .{err});
        return;
    };

    const deadline_ms = Board.time.nowMs() + PLAY_DURATION_MS;
    var mctx = TrackCtx{ .handle = melody, .notes = MELODY, .amp = 0.8, .deadline_ms = deadline_ms, .name = "melody" };
    var bctx = TrackCtx{ .handle = bass, .notes = BASS, .amp = 0.6, .deadline_ms = deadline_ms, .name = "bass" };

    const t1 = Board.runtime.Thread.spawn(.{}, writerTask, .{&mctx}) catch |err| {
        log.err("[speaker_test] spawn melody task failed: {}", .{err});
        return;
    };
    const t2 = Board.runtime.Thread.spawn(.{}, writerTask, .{&bctx}) catch |err| {
        log.err("[speaker_test] spawn bass task failed: {}", .{err});
        return;
    };

    log.info("[speaker_test] playing for {} ms...", .{PLAY_DURATION_MS});
    t1.join();
    t2.join();
    log.info("[speaker_test] done", .{});
}

pub fn main() !void {
    run(.{});
}
