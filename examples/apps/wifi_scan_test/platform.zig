//! Board Configuration - WiFi Scan Test
//!
//! Tests WiFi scanning functionality using the new scan APIs.

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;

    // WiFi HAL - provides scanning and 802.11 events
    pub const wifi = hal.wifi.from(hw.wifi_spec);

    // Net HAL - for IP events (not used in scan-only mode, but required)
    pub const net = hal.net.from(hw.net_spec);
};

pub const Board = hal.Board(spec);
