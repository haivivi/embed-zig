//! ESP32-S3 DevKit — BLE X-Proto Test

const std = @import("std");
const esp = @import("esp");
const idf = esp.idf;

pub const Runtime = idf.runtime;
pub const HciDriver = esp.impl.hci.HciDriver;
pub const heap = idf.heap;
pub const log = std.log.scoped(.app);
pub const board_name_str = "ESP32-S3";

pub const time = struct {
    pub fn sleepMs(ms: u32) void { idf.time.sleepMs(ms); }
    pub fn nowMs() u64 { return idf.time.nowMs(); }
};

pub fn isRunning() bool {
    return esp.boards.esp32s3_devkit.isRunning();
}
