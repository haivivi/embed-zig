//! Board Configuration for WebSim gpio_button example
//! Uses the esp32_devkit board (1 BOOT button + 1 RGB LED)

const hal = @import("hal");
const websim = @import("websim");
const board = websim.boards.esp32_devkit;

const spec = struct {
    pub const meta = .{ .id = "WebSim ESP32 DevKit" };
    pub const ButtonId = enum(u8) { boot = 0 };

    pub const rtc = hal.rtc.reader.from(board.rtc_spec);
    pub const log = board.log;
    pub const time = board.time;

    pub const button = hal.button.from(board.button_spec);
    pub const rgb_leds = hal.led_strip.from(board.led_spec);
};

pub const Board = hal.Board(spec);
