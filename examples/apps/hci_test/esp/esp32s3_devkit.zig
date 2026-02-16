//! ESP32-S3 DevKit Board — HCI Test

const std = @import("std");
const esp = @import("esp");
const idf = esp.idf;
const bt = idf.bt;

const board = esp.boards.esp32s3_devkit;

pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }
};

pub fn isRunning() bool {
    return board.isRunning();
}

/// BLE HCI transport — wraps idf.bt (VHCI)
pub const ble = struct {
    pub fn init() !void {
        bt.init() catch return error.BleError;
    }

    pub fn send(data: []const u8) !usize {
        return bt.send(data) catch return error.BleError;
    }

    pub fn recv(buf: []u8) !usize {
        const n = bt.recv(buf) catch return error.BleError;
        return n;
    }

    pub fn waitForData(timeout_ms: i32) bool {
        return bt.waitForData(timeout_ms);
    }
};
