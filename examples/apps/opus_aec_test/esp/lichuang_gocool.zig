//! LiChuang GoCool Board Configuration for Opus AEC Test

const std = @import("std");
const idf = @import("idf");
const hal = @import("hal");

// Board hardware definitions from platform layer
const board = @import("board_lichuang_gocool");

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
    pub const sample_rate = board.sample_rate;
    pub const pa_enable_gpio = 0xFF; // N/A - uses I2C expander
};

// ============================================================================
// Drivers (from board)
// ============================================================================

pub const AudioSystem = board.AudioSystem;
pub const PaSwitchDriver = board.PaSwitchDriver;
pub const RtcDriver = board.RtcDriver;

// I2C config for shared bus
pub const I2c = idf.I2c;
pub const i2c_sda = board.i2c_sda;
pub const i2c_scl = board.i2c_scl;
pub const i2c_freq_hz = board.i2c_freq_hz;
