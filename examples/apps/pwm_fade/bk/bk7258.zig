//! BK7258 Board Implementation for PWM Fade Example
//!
//! Hardware:
//! - PWM LED on channel 0 (1kHz, software fade)

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
};

// ============================================================================
// Drivers
// ============================================================================

pub const RtcDriver = board.RtcDriver;
pub const LedDriver = board.LedDriver;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.pwm" };
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
