//! BK7258 Board Configuration for Speaker Test
//!
//! Uses onboard DAC via Armino audio pipeline (not I2S + external DAC).
//! No external PA switch — the onboard speaker stream handles DAC directly.

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

// Re-export platform primitives
pub const log = board.log;
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
    pub const sample_rate: u32 = board.audio.sample_rate;

    // BK7258 uses onboard DAC — no I2C/I2S pins needed
    pub const pa_enable_gpio: u8 = 0; // No external PA
};

// ============================================================================
// Drivers (from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;
pub const SpeakerDriver = board.SpeakerDriver;
pub const PaSwitchDriver = board.PaSwitchDriver;

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
    pub const meta = .{ .id = "speaker.onboard" };
    pub const config = hal.MonoSpeakerConfig{
        .sample_rate = Hardware.sample_rate,
    };
};
