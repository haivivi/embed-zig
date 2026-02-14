//! Board Configuration for WebSim adc_button
//! Uses the korvo2_v3 board (6 ADC buttons + 9 LED strip)

const hal = @import("hal");
const websim = @import("websim");
const board = websim.boards.korvo2_v3;

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
    pub const meta = .{ .id = "WebSim Korvo-2 V3" };

    // Button ID type (required for button_group)
    pub const ButtonId = OuterButtonId;

    // Required primitives
    pub const rtc = hal.rtc.reader.from(board.rtc_spec);
    pub const log = board.log;
    pub const time = board.time;

    // HAL peripherals
    pub const buttons = hal.button_group.from(board.adc_button_spec, OuterButtonId);
    pub const rgb_leds = hal.led_strip.from(board.led_spec);
};

pub const Board = hal.Board(spec);
