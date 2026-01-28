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

const OuterButtonId = ButtonId;

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Button ID type (required for button_group)
    pub const ButtonId = OuterButtonId;

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    // HAL peripherals
    pub const buttons = hal.button_group.from(hw.button_group_spec, OuterButtonId);
};

pub const Board = hal.Board(spec);
