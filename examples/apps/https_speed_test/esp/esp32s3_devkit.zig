//! ESP32-S3 DevKit Board Implementation for HTTPS Speed Test
//!
//! Hardware:
//! - WiFi Station mode (event-driven)
//! - BSD Sockets via LWIP
//! - Pure Zig TLS

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
// Crypto Implementation (mbedTLS-based, hardware accelerated)
// ============================================================================

pub const crypto = board.crypto;
pub const allocator = esp.idf.heap.psram;

// Certificate Store type for TLS verification
pub const cert_store = crypto.x509.CaStore;

// ============================================================================
// Network Interface Manager (implements trait.net)
// ============================================================================

pub const net_impl = impl.net;
pub const net = impl.net; // Alias for platform.zig

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
// Environment Variables
// ============================================================================

pub const env = struct {
    pub const wifi_ssid = @import("env").WIFI_SSID;
    pub const wifi_password = @import("env").WIFI_PASSWORD;
    pub const test_server = @import("env").TEST_SERVER;
};
pub const runtime = idf.runtime;
