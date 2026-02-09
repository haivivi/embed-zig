//! ESP32-S3 DevKit Board Implementation for mqtt0 Test
//!
//! Hardware:
//! - WiFi Station mode (event-driven)
//! - BSD Sockets via LWIP
//! - FreeRTOS Mutex (for mqtt0 Rt)

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const board = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
};

// ============================================================================
// Socket Implementation (from ESP IDF)
// ============================================================================

pub const socket = idf.socket.Socket;

// ============================================================================
// Drivers (re-export from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;
pub const WifiDriver = board.WifiDriver;
pub const NetDriver = board.NetDriver;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const wifi_spec = board.wifi_spec;
pub const net_spec = board.net_spec;

// ============================================================================
// Platform Primitives (re-export from central board)
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// mqtt0 Runtime — FreeRTOS Mutex + ESP time
// ============================================================================

pub const MqttRt = struct {
    pub const Mutex = idf.runtime.Mutex;
    pub const Time = struct {
        pub fn sleepMs(ms: u32) void {
            idf.time.sleepMs(ms);
        }
        pub fn getTimeMs() u64 {
            return idf.time.nowMs();
        }
    };
};
