//! Korvo-2 V3 Board Configuration for LED Strip Animation Test
//!
//! Uses pre-configured drivers from esp.boards.korvo2_v3

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const board = esp.boards.korvo2_v3;

// ============================================================================
// Re-export board definitions
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;
pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const led_type = "tca9554";
    pub const led_count: u32 = 1;
};

// ============================================================================
// Drivers (from board)
// ============================================================================

pub const LedDriver = board.LedDriver;
pub const RtcDriver = board.RtcDriver;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.main" };
};
