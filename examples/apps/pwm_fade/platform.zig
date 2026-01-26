//! Platform Configuration - PWM Fade
//!
//! This example only supports boards with PWM-capable onboard LED.

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
};

const spec = struct {
    pub const rtc = hal.RtcReader(hw.rtc_spec);
    pub const led = hal.Led(hw.led_spec);
};

pub const Board = hal.Board(spec);

// SAL (from platform)
pub const sal = hw.sal;
