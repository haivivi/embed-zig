//! Board Configuration - HAL v5

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .korvo2_v3 => @import("boards/korvo2_v3.zig"),
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
    .sim_raylib => @import("boards/sim_raylib.zig"),
};

const spec = struct {
    pub const rtc = hal.RtcReader(hw.rtc_spec);
    pub const ButtonId = enum(u8) { boot = 0 };
    pub const button = hal.Button(hw.button_spec);
    pub const rgb_leds = hal.RgbLedStrip(hw.led_spec);
};

pub const Board = hal.Board(spec);

// SAL (from platform)
pub const sal = hw.sal;

// Export hw for simulator access
pub const Hardware = hw;
