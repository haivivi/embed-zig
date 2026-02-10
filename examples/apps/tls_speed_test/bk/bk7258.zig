//! BK7258 Board Implementation for TLS Speed Test

const bk = @import("bk");
const board = bk.boards.bk7258;

pub const Hardware = struct {
    pub const name = board.name;
};

pub const socket = board.socket;
pub const crypto = board.crypto;
pub const RtcDriver = board.RtcDriver;

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const wifi_spec = board.wifi_spec;
pub const net_spec = board.net_spec;

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
