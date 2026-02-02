//! ESP32-S3 DevKit Board Implementation
//!
//! Minimal implementation for async testing

const std = @import("std");
const esp = @import("esp");

const idf = esp.idf;

// Platform primitives
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

// Hardware parameters from lib/esp/boards
const hw_params = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
};

// ============================================================================
// RTC Driver (required by hal.Board)
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
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};
