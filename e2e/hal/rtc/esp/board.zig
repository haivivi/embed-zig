//! ESP board for e2e hal/rtc
const std = @import("std");
const idf = @import("idf");
const esp = @import("esp");

pub const log = std.log.scoped(.e2e);

pub const time = struct {
    pub fn sleepMs(ms: u32) void { idf.time.sleepMs(ms); }
    pub fn nowMs() u64 { return idf.time.nowMs(); }
};

pub const rtc_spec = struct {
    pub const Driver = esp.boards.esp32s3_devkit.RtcDriver;
    pub const meta = .{ .id = "esp_rtc" };
};
