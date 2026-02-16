//! ESP32-S3 DevKit Board — Timer Test

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const board = esp.boards.esp32s3_devkit;

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
};

pub const RtcDriver = board.RtcDriver;

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};
