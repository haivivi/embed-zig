//! Platform Configuration - HAL v5

const hal = @import("hal");
const build_options = @import("build_options");

pub const selected_board = build_options.board;

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("esp/korvo2_v3.zig"),
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    // HAL peripherals
    pub const rgb_leds = hal.led_strip.from(hw.led_spec);
};

pub const Board = hal.Board(spec);
