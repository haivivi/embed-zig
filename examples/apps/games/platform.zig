//! Games — Board Configuration

const hal = @import("hal");
const websim = @import("websim");
const display_pkg = @import("display");
const hw = @import("websim/standard.zig");

pub const ButtonId = hw.ButtonId;

const spec = struct {
    pub const meta = .{ .id = "Games" };
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = websim.sal.log;
    pub const time = websim.sal.time;
    pub const buttons = hal.button_group.from(hw.adc_button_spec, ButtonId);
    pub const button = hal.button.from(hw.power_button_spec);
    pub const vfs = hal.fs.from(hw.fs_spec);
};

pub const Board = hal.Board(spec);

pub const Display = display_pkg.SpiLcd(websim.SimSpi, websim.SimDcPin, .{
    .width = 240,
    .height = 240,
    .color_format = .rgb565,
    .render_mode = .partial,
    .buf_lines = 20,
});
