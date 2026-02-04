//! ESP32-S3 DevKit Board Implementation for NTP Test
//!
//! Hardware:
//! - WiFi Station mode (event-driven)
//! - BSD Sockets via LWIP

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const impl = esp.impl;
const hw_params = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
};

// ============================================================================
// Socket Implementation (from ESP IDF)
// ============================================================================

pub const socket = idf.socket.Socket;

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.time.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

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
