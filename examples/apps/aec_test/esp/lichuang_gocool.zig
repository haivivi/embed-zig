//! LiChuang GoCool Board Configuration for AEC Test
//!
//! Uses AudioSystem from esp.boards.lichuang_gocool

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const board = esp.boards.lichuang_gocool;

// ============================================================================
// Re-export board definitions
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;
pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Hardware Info (for app.zig compatibility)
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const sample_rate = board.sample_rate;
    // PA is controlled via PCA9557, not direct GPIO
    pub const pa_enable_gpio = 0xFF; // N/A - uses I2C expander
};

// ============================================================================
// Drivers (from board)
// ============================================================================

pub const AudioSystem = board.AudioSystem;
pub const PaSwitchDriver = board.PaSwitchDriver;
pub const RtcDriver = board.RtcDriver;

// I2C config for shared bus
pub const idf = esp.idf;
pub const i2c_sda = board.i2c_sda;
pub const i2c_scl = board.i2c_scl;
pub const i2c_freq_hz = board.i2c_freq_hz;

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const pa_switch_spec = struct {
    pub const Driver = PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};
