//! ESP32-S3 DevKit Board Implementation for Net Event Test
//!
//! Tests the Net HAL event system:
//! - lib/esp/src/idf/net/ (IP_EVENT handling)
//! - lib/esp/src/impl/net.zig (NetDriver)
//! - lib/hal/src/net.zig (HAL wrapper)

const std = @import("std");
const idf = @import("esp");

const hw_params = idf.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
};

// ============================================================================
// RTC Driver (minimal - just provides uptime)
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// WiFi Driver - from impl/wifi.zig
// ============================================================================

pub const WifiDriver = idf.impl.wifi.WifiDriver;

// ============================================================================
// Net Driver - from impl/net.zig (THIS IS WHAT WE'RE TESTING)
// ============================================================================

pub const NetDriver = idf.impl.net.NetDriver;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

/// WiFi spec - uses impl/wifi.zig
pub const wifi_spec = idf.impl.wifi.wifi_spec;

/// Net spec - uses impl/net.zig (THE TARGET OF THIS TEST)
pub const net_spec = idf.impl.net.net_spec;

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.sal.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}
