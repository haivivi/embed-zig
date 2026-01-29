//! Board Configuration - WiFi DNS Lookup

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

    // WiFi HAL peripheral
    pub const wifi = hal.wifi.from(hw.wifi_spec);

    // Socket trait (for DNS resolver)
    pub const socket = hw.socket;
};

pub const Board = hal.Board(spec);
