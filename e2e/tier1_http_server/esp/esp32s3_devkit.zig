const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const board = esp.boards.esp32s3_devkit;

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
};

pub const socket = idf.socket.Socket;

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

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        board.time.sleepMs(ms);
    }
    pub fn nowMs() u64 {
        return board.time.nowMs();
    }
};

pub fn isRunning() bool {
    return board.isRunning();
}

pub const allocator = idf.heap.psram;
