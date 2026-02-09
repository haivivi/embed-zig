//! Platform Configuration - PWM Fade
//!
//! This example only supports boards with PWM-capable onboard LED.

const hal = @import("hal");
const build_options = @import("build_options");

const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
    .bk7258 => @import("bk/bk7258.zig"),
    else => @compileError("unsupported board for pwm_fade"),
};

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    // HAL peripherals
    pub const led = hal.led.from(hw.led_spec);
};

pub const Board = hal.Board(spec);
