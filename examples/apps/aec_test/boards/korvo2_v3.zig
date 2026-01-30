//! Korvo-2 V3 Board Configuration for AEC Test
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
// Hardware Info (for app.zig compatibility)
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const sample_rate = board.sample_rate;
    pub const pa_enable_gpio = board.pa_gpio;
};

// ============================================================================
// Drivers (from board)
// ============================================================================

pub const MicDriver = board.MicDriver;
pub const SpeakerDriver = board.SpeakerDriver;
pub const PaSwitchDriver = board.PaSwitchDriver;
pub const RtcDriver = board.RtcDriver;

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

pub const mic_spec = struct {
    pub const Driver = MicDriver;
    pub const meta = .{ .id = "mic.es7210" };
    pub const config = hal.mic.Config{
        .sample_rate = Hardware.sample_rate,
    };
};
