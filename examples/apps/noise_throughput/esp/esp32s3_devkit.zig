//! ESP32-S3 DevKit Board Implementation for Noise Throughput Test
//!
//! Hardware:
//! - WiFi Station mode
//! - BSD Sockets via LWIP (UDP)

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const impl = esp.impl;
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
// Drivers
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
// Platform Primitives
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Environment Variables
// ============================================================================

pub const env = struct {
    pub const wifi_ssid = @import("env").env.wifi_ssid;
    pub const wifi_password = @import("env").env.wifi_password;
};
