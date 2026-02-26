//! loop_back_test — mic to speaker loopback via AudioEngine track

const std = @import("std");
const audio = @import("audio");
const platform = @import("platform.zig");

const Board = platform.Board;
const log = Board.log;

const SAMPLE_RATE: u32 = 16000;
const FRAME_SIZE: u32 = 160;
const RUN_DURATION_MS: u32 = 10_000;

const EngineType = audio.engine.AudioEngine(
    Board.runtime,
    Board.DuplexAudio.Mic,
    Board.DuplexAudio.Speaker,
    .{
        .enable_aec = true,
        .enable_ns = true,
        .frame_size = FRAME_SIZE,
        .sample_rate = SAMPLE_RATE,
        .RefReader = Board.DuplexAudio.RefReader,
    },
);

const BridgeCtx = struct {
    engine: *EngineType,
    handle: EngineType.TrackHandle,
    stop_flag: *std.atomic.Value(bool),
};

fn micToTrackTask(ctx: *BridgeCtx) void {
    const fmt = audio.Format{ .rate = SAMPLE_RATE, .channels = .mono };
    var frame: [FRAME_SIZE]i16 = undefined;

    while (!ctx.stop_flag.load(.acquire)) {
        const n = ctx.engine.readClean(&frame) orelse break;
        if (n == 0) continue;

        _ = ctx.handle.track.write(fmt, frame[0..n]) catch break;
    }
}

pub fn run(_: anytype) void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    Board.initAudio() catch |err| {
        log.err("[loop_back_test] Audio init failed: {}", .{err});
        return;
    };
    defer Board.deinitAudio();

    log.info("[loop_back_test] ==========================================", .{});
    log.info("[loop_back_test] mic -> NS/AEC -> track -> speaker", .{});
    log.info("[loop_back_test] ==========================================", .{});

    var duplex = Board.DuplexAudio.init(allocator) catch |err| {
        log.err("[loop_back_test] Duplex init failed: {}", .{err});
        return;
    };
    defer duplex.stop();

    duplex.start() catch |err| {
        log.err("[loop_back_test] Duplex start failed: {}", .{err});
        return;
    };

    var mic = duplex.mic();
    var spk = duplex.speaker();
    var ref = duplex.refReader();

    var engine = EngineType.init(allocator, &mic, &spk, &ref) catch |err| {
        log.err("[loop_back_test] Engine init failed: {}", .{err});
        return;
    };
    defer engine.deinit();

    const loop_track = engine.createTrack(.{ .label = "loopback" }) catch |err| {
        log.err("[loop_back_test] create loopback track failed: {}", .{err});
        return;
    };
    defer engine.destroyTrackCtrl(loop_track.ctrl);

    engine.start() catch |err| {
        log.err("[loop_back_test] Engine start failed: {}", .{err});
        return;
    };

    var stop_flag = std.atomic.Value(bool).init(false);
    var ctx = BridgeCtx{
        .engine = &engine,
        .handle = loop_track,
        .stop_flag = &stop_flag,
    };

    const bridge = Board.runtime.Thread.spawn(.{}, micToTrackTask, .{&ctx}) catch |err| {
        log.err("[loop_back_test] spawn bridge task failed: {}", .{err});
        engine.stop();
        return;
    };

    log.info("[loop_back_test] running loopback for {} ms...", .{RUN_DURATION_MS});
    Board.time.sleepMs(RUN_DURATION_MS);

    stop_flag.store(true, .release);
    engine.stop();
    bridge.join();

    log.info("[loop_back_test] done", .{});
}

pub fn main() !void {
    run(.{});
}
