//! speaker_direct_test — test panic handler with old crash code

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const time = Board.time;
const log = Board.log;

const FRAME_SIZE: u32 = Board.engine_frame_size;

pub fn run(_: anytype) void {
    const allocator = Board.allocator();

    var duplex = Board.DuplexAudio.init(allocator) catch return;
    defer duplex.stop();

    var spk = duplex.speaker();
    // Use -1 (0xFFFF) which will trigger u32 shift overflow
    var frame: [FRAME_SIZE]i16 = undefined;
    for (&frame) |*s| s.* = -1;

    const n = spk.write(&frame) catch |err| {
        log.err("[diag] write failed: {}", .{err});
        return;
    };
    log.info("[diag] write OK! n={}", .{n});

    while (true) {
        time.sleepMs(1000);
    }
}

pub fn main() !void {
    run(.{});
}
