//! Platform Configuration - HAL v5
//!
//! Note: Timer callback only supports DevKit (WS2812 LED for visual feedback)

const hal = @import("hal");
const hw = @import("esp/esp32s3_devkit.zig");

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
