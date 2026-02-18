//! BitMonster Board — 320x320 screen + D-pad + confirm/back + power
//!
//! - 320x320 SPI LCD (RGB565)
//! - 6 ADC buttons: up, down, left, right, back, confirm
//! - 1 power button (independent GPIO)

const hal = @import("hal");
const display = @import("display");
const drivers = @import("../../impl/drivers.zig");
const spi_sim = @import("../../impl/spi.zig");
const state = @import("../../impl/state.zig");

pub const ButtonId = enum(u8) {
    up = 0,
    down = 1,
    left = 2,
    right = 3,
    back = 4,
    confirm = 5,
};

pub const adc_ranges = &[_]hal.ButtonGroupRange{
    .{ .id = 0, .min = 100, .max = 300 }, // up: ~200
    .{ .id = 1, .min = 400, .max = 600 }, // down: ~500
    .{ .id = 2, .min = 700, .max = 900 }, // left: ~800
    .{ .id = 3, .min = 1000, .max = 1200 }, // right: ~1100
    .{ .id = 4, .min = 1300, .max = 1500 }, // back: ~1400
    .{ .id = 5, .min = 1600, .max = 1800 }, // confirm: ~1700
};

pub const adc_button_spec = struct {
    pub const Driver = drivers.AdcButtonDriver;
    pub const ranges = adc_ranges;
    pub const ref_value: u16 = 4095;
    pub const ref_tolerance: u16 = 200;
    pub const meta = .{ .id = "buttons.adc" };
};

pub const power_button_spec = struct {
    pub const Driver = drivers.PowerButtonDriver;
    pub const meta = .{ .id = "button.power" };
};

pub const rtc_spec = struct {
    pub const Driver = drivers.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const display_width: u16 = 320;
pub const display_height: u16 = 320;

pub const Display = display.SpiLcd(spi_sim.SimSpi, spi_sim.SimDcPin, .{
    .width = display_width,
    .height = display_height,
    .color_format = .rgb565,
    .render_mode = .partial,
    .buf_lines = 20,
});

pub const board_config_json =
    \\{"name":"BitMonster","chip":"WebSim",
    \\"buttons":{"adc":[
    \\{"name":"UP","value":200},{"name":"DOWN","value":500},
    \\{"name":"LEFT","value":800},{"name":"RIGHT","value":1100},
    \\{"name":"BACK","value":1400},{"name":"OK","value":1700}
    \\],"boot":false,"power":true},
    \\"display":{"width":320,"height":320}}
;

pub const log = drivers.sal.log;
pub const time = drivers.sal.time;
pub const isRunning = drivers.sal.isRunning;
