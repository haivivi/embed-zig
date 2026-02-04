//! Korvo-2 V3 Board Implementation for NTP Test
//!
//! Hardware:
//! - WiFi Station mode (event-driven)
//! - BSD Sockets via LWIP

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const impl = esp.impl;
const board = esp.boards.korvo2_v3;

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
// RTC Driver
// ============================================================================

pub const RtcDriver = board.RtcDriver;

// ============================================================================
// WiFi Driver (Event-Driven)
// ============================================================================

pub const WifiDriver = impl.wifi.WifiDriver;

// ============================================================================
// Net Driver (for IP events)
// ============================================================================

pub const NetDriver = impl.net.NetDriver;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const wifi_spec = impl.wifi.wifi_spec;
pub const net_spec = impl.net.net_spec;

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.time.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}
