const bk = @import("bk");
const board = bk.boards.bk7258;

pub const Hardware = struct { pub const name = board.name; };
pub const crypto = board.crypto;
pub const RtcDriver = board.RtcDriver;
pub const rtc_spec = struct { pub const Driver = RtcDriver; pub const meta = .{ .id = "rtc" }; };
pub const log = board.log;
pub const time = board.time;
pub fn isRunning() bool { return board.isRunning(); }
