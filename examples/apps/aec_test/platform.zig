//! Platform Configuration - AEC Test
//!
//! Supports: Korvo-2 V3 (ES7210 ADC + ES8311 DAC + AEC)
//!
//! Uses HAL Board abstraction for proper driver lifecycle management.

const hal = @import("hal");
const hw = @import("boards/korvo2_v3.zig");

pub const Hardware = hw.Hardware;

// Re-export platform primitives (for direct access outside Board)
pub const log = hw.log;
pub const time = hw.time;

/// Platform spec for hal.Board
const spec = struct {
    pub const meta = .{ .id = Hardware.name };

    // Required: time source
    pub const rtc = hal.rtc.reader.from(hw.rtc_spec);

    // Audio peripherals
    pub const mic = hal.mic.from(hw.mic_spec);
    pub const speaker = hal.mono_speaker.from(hw.speaker_spec);

    // PA (Power Amplifier) switch
    pub const pa_switch = hal.switch_.from(hw.pa_switch_spec);

    // Platform primitives
    pub const log = hw.log;
    pub const time = hw.time;
    pub const isRunning = hw.isRunning;
};

/// Board type using HAL abstraction
pub const Board = hal.Board(spec);
