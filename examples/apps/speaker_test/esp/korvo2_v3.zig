//! Korvo-2 V3 Board Configuration for Speaker Test
//!
//! Uses pre-configured drivers from esp.boards.korvo2_v3
//! Note: Speaker-only test uses standalone I2S (no AEC/mic)

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const board = esp.boards.korvo2_v3;

// Re-export platform primitives
pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// Hardware Info (re-export from central board)
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const sample_rate: u32 = board.sample_rate;

    // I2C pins
    pub const i2c_sda: u8 = board.i2c_sda;
    pub const i2c_scl: u8 = board.i2c_scl;

    // I2S pins for speaker
    pub const i2s_port: u8 = board.i2s_port;
    pub const i2s_bclk: u8 = board.i2s_bclk;
    pub const i2s_ws: u8 = board.i2s_ws;
    pub const i2s_dout: u8 = board.i2s_dout;
    pub const i2s_mclk: u8 = board.i2s_mclk;

    // PA enable
    pub const pa_enable_gpio: u8 = board.pa_gpio;

    // ES8311 I2C address
    pub const es8311_addr: u7 = board.es8311_addr;
};

// ============================================================================
// Drivers (re-export from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;
pub const PaSwitchDriver = board.PaSwitchDriver;
pub const SpeakerDriver = board.SpeakerDriver;

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

pub const speaker_spec = struct {
    pub const Driver = SpeakerDriver;
    pub const meta = .{ .id = "speaker.es8311" };
    pub const config = hal.MonoSpeakerConfig{
        .sample_rate = Hardware.sample_rate,
    };
};
