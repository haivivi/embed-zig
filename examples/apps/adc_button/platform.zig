//! Platform Configuration - HAL v5
//!
//! Note: ADC Button only supports Korvo-2 V3 (has ADC buttons)

const hal = @import("hal");
const hw = @import("boards/korvo2_v3.zig");

pub const ButtonId = enum(u8) {
    vol_up = 0,
    vol_down = 1,
    set = 2,
    play = 3,
    mute = 4,
    rec = 5,

    pub fn name(self: @This()) []const u8 {
        return switch (self) {
            .vol_up => "VOL+",
            .vol_down => "VOL-",
            .set => "SET",
            .play => "PLAY",
            .mute => "MUTE",
            .rec => "REC",
        };
    }
};

const spec = struct {
    // Required: time source
    pub const rtc = hal.RtcReader(hw.rtc_spec);

    // ADC button group (6 buttons via resistor ladder)
    pub const buttons = hal.ButtonGroup(hw.button_group_spec, ButtonId);
};

pub const Board = hal.Board(spec);
pub const Hardware = hw.Hardware;

// Export SAL for app.zig
pub const sal = hw.sal;
