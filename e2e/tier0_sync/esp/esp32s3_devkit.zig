//! ESP32-S3 DevKit Board Implementation
//!
//! Minimal implementation for async testing

const std = @import("std");
const esp = @import("esp");

const board = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
};

// ============================================================================
// Drivers (re-export from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

// ============================================================================
// Platform Primitives (re-export from central board)
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
