//! Board Configuration — Noise Throughput Test

const hal = @import("hal");
const build_options = @import("build_options");

pub const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;

    // WiFi HAL peripheral
    pub const wifi = hal.wifi.from(hw.wifi_spec);

    // Net HAL peripheral
    pub const net = hal.net.from(hw.net_spec);

    // Socket
    pub const socket = hw.socket;
};

pub const Board = hal.Board(spec);

/// Board environment variables
pub const env = hw.env;
