//! Board Configuration for WebSim standard board
//!
//! 240x240 screen + 7 ADC buttons + power button + LED

const hal = @import("hal");
const websim = @import("websim");
const std_board = websim.boards;

pub const ButtonId = std_board.ButtonId;

const spec = struct {
    pub const meta = .{ .id = "WebSim Standard" };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(std_board.rtc_spec);
    pub const log = std_board.log;
    pub const time = std_board.time;

    // Peripherals (managed by Board)
    pub const buttons = hal.button_group.from(std_board.adc_button_spec, ButtonId);
    pub const button = hal.button.from(std_board.power_button_spec);
    pub const rgb_leds = hal.led_strip.from(std_board.led_spec);
};

pub const Board = hal.Board(spec);

// Display is managed separately (not yet integrated into hal.Board)
pub const Display = hal.display.from(std_board.display_spec);
