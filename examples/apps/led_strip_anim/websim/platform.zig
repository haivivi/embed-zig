//! Board Configuration for WebSim led_strip_anim
//! Uses the esp32_devkit board (1 RGB LED)

const hal = @import("hal");
const websim = @import("websim");
const board = websim.boards.esp32_devkit;

const spec = struct {
    pub const meta = .{ .id = "WebSim ESP32 DevKit" };

    pub const rtc = hal.rtc.reader.from(board.rtc_spec);
    pub const log = board.log;
    pub const time = board.time;

    pub const rgb_leds = hal.led_strip.from(board.led_spec);
};

pub const Board = hal.Board(spec);
