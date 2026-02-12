//! Board Configuration for H106 UI Prototype

const hal = @import("hal");
const display = @import("display");
const websim = @import("websim");
const hw = @import("websim/standard.zig");

pub const ButtonId = hw.ButtonId;

const rtc_spec = struct {
    pub const Driver = websim.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

const power_button_spec = struct {
    pub const Driver = websim.PowerButtonDriver;
    pub const meta = .{ .id = "button.power" };
};

const spec = struct {
    pub const meta = .{ .id = "H106 Prototype" };
    pub const rtc = hal.rtc.reader.from(rtc_spec);
    pub const log = websim.sal.log;
    pub const time = websim.sal.time;
    pub const buttons = hal.button_group.from(hw.adc_button_spec, ButtonId);
    pub const button = hal.button.from(power_button_spec);
    pub const rgb_leds = hal.led_strip.from(hw.led_spec);
};

pub const Board = hal.Board(spec);
pub const Display = display.from(hw.display_spec);
