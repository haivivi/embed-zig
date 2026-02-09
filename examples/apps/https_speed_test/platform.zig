//! Board Configuration - HTTPS Speed Test

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for https_speed_test"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;

    pub const wifi = hal.wifi.from(hw.wifi_spec);
    pub const net = hal.net.from(hw.net_spec);
    pub const socket = hw.socket;
    pub const crypto = hw.crypto;
};

pub const Board = hal.Board(spec);
