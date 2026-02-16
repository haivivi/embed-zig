//! ESP32-S3 DevKit Board Implementation for WiFi DNS Lookup

const std = @import("std");
const esp = @import("esp");

const board = esp.boards.esp32s3_devkit;

pub const Hardware = struct {
    pub const name = board.name;
};

pub const socket = esp.idf.socket.Socket;
pub const RtcDriver = board.RtcDriver;
pub const WifiDriver = board.WifiDriver;
pub const NetDriver = board.NetDriver;

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const wifi_spec = board.wifi_spec;
pub const net_spec = board.net_spec;

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
