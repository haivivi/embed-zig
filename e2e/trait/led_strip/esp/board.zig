//! ESP board for e2e hal/led_strip (DevKit WS2812 on GPIO48)
const std = @import("std");
const idf = @import("idf");
const esp = @import("esp");

pub const log = std.log.scoped(.e2e);
pub const LedDriver = esp.boards.esp32s3_devkit.LedDriver;

pub const time = struct {
    pub fn sleepMs(ms: u32) void { idf.time.sleepMs(ms); }
};
