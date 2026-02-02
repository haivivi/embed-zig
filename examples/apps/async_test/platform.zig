//! Platform Configuration - Async Test
//!
//! Minimal platform for async task testing

const hal = @import("hal");
const hw = @import("boards/esp32s3_devkit.zig");

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required primitives
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);
    pub const log = hw.log;
    pub const time = hw.time;
};

pub const Board = hal.Board(spec);
