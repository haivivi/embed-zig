//! BK7258 Board Implementation for NVS Storage

const bk = @import("bk");
const board = bk.boards.bk7258;

pub const Hardware = struct {
    pub const name = board.name;
};

pub const RtcDriver = board.RtcDriver;
pub const KvsDriver = board.KvsDriver;

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const kvs_spec = struct {
    pub const Driver = KvsDriver;
    pub const meta = .{ .id = "kvs.easyflash" };
};

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
