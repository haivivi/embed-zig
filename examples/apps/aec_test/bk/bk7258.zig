//! BK7258 Board Configuration for AEC Test

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

pub const Hardware = struct {
    pub const name = board.name;
};

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

pub const rtc_spec = struct {
    pub const Driver = board.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const AudioSystem = board.AudioSystem;
