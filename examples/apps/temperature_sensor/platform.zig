//! Temperature Sensor Platform Configuration
//!
//! Defines the board-independent HAL spec for the temperature sensor app.

const build_options = @import("build_options");
const hal = @import("hal");

// Select board implementation based on build option
const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("boards/esp32s3_devkit.zig"),
};

/// Platform-specific SAL (logging, timing, etc.)
pub const sal = hw.sal;

/// Board specification for hal.Board
pub const spec = struct {
    pub const rtc = hal.RtcReader(hw.rtc_spec);
    pub const temp = hal.TempSensor(hw.temp_spec);
};
