//! Platform Configuration - Hello BK7258

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for hello_bk"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;
    pub const wifi = hal.wifi.from(hw.wifi_spec);
    pub const net = hal.net.from(hw.net_spec);
};

pub const Board = hal.Board(spec);
