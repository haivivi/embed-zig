//! BK7258 Board Configuration for ADC Piano
//!
//! Hardware:
//! - 4 ADC buttons on SARADC channel 4 (GPIO 28)
//!   Voltage ranges from Armino adc_key:
//!     PREV:       1-100 mV  → raw   2- 170
//!     NEXT:     600-750 mV  → raw 1024-1280
//!     PLAY:   1300-1500 mV  → raw 2218-2560
//!     MENU:   1900-2100 mV  → raw 3242-3584
//!   Conversion: raw = mV * 4096 / 2400
//! - Onboard DAC speaker (8kHz mono)

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;
const armino = bk.armino;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const sample_rate: u32 = board.audio.sample_rate;
    pub const pa_enable_gpio: u8 = 0; // No external PA
    pub const adc_channel: u32 = 4; // SARADC channel 4 (GPIO 28)
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = board.log;
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// ADC Reader for Button Group (SARADC)
// ============================================================================

pub const AdcReader = struct {
    const Self = @This();

    initialized: bool = false,

    pub fn init() !Self {
        return .{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    pub fn readRaw(_: *Self) u16 {
        return armino.adc.read(Hardware.adc_channel) catch 4095;
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = board.RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

pub const pa_switch_spec = struct {
    pub const Driver = board.PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};

pub const speaker_spec = struct {
    pub const Driver = board.SpeakerDriver;
    pub const meta = .{ .id = "speaker.onboard" };
    pub const config = hal.MonoSpeakerConfig{ .sample_rate = Hardware.sample_rate };
};

/// ADC button ranges for BK7258 dev board
/// Converted from Armino mV thresholds to 12-bit raw values:
///   raw = mV * 4096 / 2400
pub const button_group_spec = struct {
    pub const Driver = AdcReader;

    pub const ranges = &[_]hal.button_group.Range{
        .{ .id = 0, .min = 2, .max = 170 }, // Do  (PREV:  1-100 mV)
        .{ .id = 1, .min = 1024, .max = 1280 }, // Re  (NEXT:  600-750 mV)
        .{ .id = 2, .min = 2218, .max = 2560 }, // Mi  (PLAY:  1300-1500 mV)
        .{ .id = 3, .min = 3242, .max = 3584 }, // Fa  (MENU:  1900-2100 mV)
    };

    pub const ref_value: u16 = 4095;
    pub const ref_tolerance: u16 = 200;

    pub const meta = .{ .id = "buttons.adc" };
};
