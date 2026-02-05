//! ESP32-S3 DevKit Board Implementation for WiFi DNS Lookup
//!
//! Hardware:
//! - WiFi Station mode (event-driven)
//! - BSD Sockets via LWIP
//! - mbedTLS crypto (hardware accelerated on ESP32)

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
// Crypto Implementation - mbedTLS (ESP32 hardware accelerated)
//
// Requires sdkconfig: esp32s3_wifi_xip_mbedtls
// - CONFIG_MBEDTLS_HKDF_C=y
// - CONFIG_MBEDTLS_GCM_C=y
// - CONFIG_MBEDTLS_CHACHAPOLY_C=y
// ============================================================================

/// Full mbedTLS crypto suite (includes x509 for certificate verification)
pub const crypto = board.crypto;

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
