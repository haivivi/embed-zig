//! Temperature Sensor Platform Configuration
//!
//! Defines the board-independent HAL spec for the temperature sensor app.

const build_options = @import("build_options");
const hal = @import("hal");

// Select board implementation based on build option
const hw = switch (build_options.board) {
    .esp32s3_devkit => @import("esp/esp32s3_devkit.zig"),
};

/// Board specification for hal.Board
const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;

    // HAL peripherals
    pub const temp = hal.temp_sensor.from(hw.temp_spec);
};

pub const Board = hal.Board(spec);
