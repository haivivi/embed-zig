//! Platform Configuration - HAL v5

const hal = @import("hal");
const build_options = @import("build_options");

pub const BoardType = build_options.@"build.BoardType";
pub const selected_board: BoardType = build_options.board;

const hw = switch (selected_board) {
    .korvo2_v3 => @import("boards/korvo2_v3.zig"),
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
};

const spec = struct {
    // Required: time source
    pub const rtc = hal.RtcReader(hw.rtc_spec);

    // LED strip
    pub const rgb_leds = hal.RgbLedStrip(hw.led_spec);
};

pub const Board = hal.Board(spec);
pub const Hardware = hw.Hardware;

// Export SAL for app.zig
pub const sal = hw.sal;
