//! Platform Configuration - Microphone Test
//!
//! Supports: Korvo-2 V3 (ES7210 4-channel ADC)

const hal = @import("hal");
const hw = @import("boards/korvo2_v3.zig");

const spec = struct {
    pub const meta = .{ .id = hw.Hardware.name };

    // Required: time source
    pub const rtc = hw.rtc_spec;

    // Microphone (ES7210 via I2S)
    pub const mic = hw.mic_spec;

    // Platform primitives
    pub const log = hw.log;
    pub const time = hw.time;
};

pub const Board = hal.Board(spec);
