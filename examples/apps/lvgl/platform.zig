//! Board Configuration for LVGL Demo
//!
//! Currently supports: websim standard board (240x240 screen + 7 buttons + power)
//! Later: ESP SPI LCD boards

const hal = @import("hal");
const hw = @import("websim/standard.zig");

pub const ButtonId = hw.ButtonId;

const spec = struct {
    pub const meta = .{ .id = hw.name };

    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    pub const buttons = hal.button_group.from(hw.adc_button_spec, ButtonId);
    pub const button = hal.button.from(hw.power_button_spec);
    pub const rgb_leds = hal.led_strip.from(hw.led_spec);
};

pub const Board = hal.Board(spec);

/// Display is managed separately (not yet in hal.Board)
pub const Display = hal.display.from(hw.display_spec);
