//! Platform Configuration — Minimal Opus Test
//!
//! Simplest platform: just ESP32-S3 DevKit, no extra hardware.

const hw = @import("esp/esp32s3_devkit.zig");

pub const Board = struct {
    pub const log = hw.log;
    pub const time = hw.time;
};
