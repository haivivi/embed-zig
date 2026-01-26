//! Platform Configuration - HAL v5
//!
//! Note: Timer callback only supports DevKit (WS2812 LED for visual feedback)

const hal = @import("hal");
const hw = @import("boards/esp32s3_devkit.zig");

const spec = struct {
    // Required: time source
    pub const rtc = hal.RtcReader(hw.rtc_spec);

    // LED strip for timer visual feedback
    pub const rgb_leds = hal.RgbLedStrip(hw.led_spec);
};

pub const Board = hal.Board(spec);
pub const Hardware = hw.Hardware;

// Export SAL for app.zig
pub const sal = hw.sal;
