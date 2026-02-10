//! BK7258 Board Configuration for ADC Piano
//!
//! Hardware:
//! - 4 matrix keys (K1-K4) on GPIO 6/7/8 (matrix scan)
//!   K1=GPIO6 (Do), K2=GPIO7 (Re), K3=GPIO8 (Mi), K4=matrix G6→G7 (Fa)
//! - Onboard DAC speaker (8kHz mono)

const bk = @import("bk");
const hal = @import("hal");

const board = bk.boards.bk7258;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const sample_rate: u32 = board.audio.sample_rate;
    pub const pa_enable_gpio: u8 = 0; // No external PA

    extern fn bk_zig_adc_scan_all() void;
    pub fn debugScan() void {
        bk_zig_adc_scan_all();
    }
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

/// ADC button group on P28 (SARADC channel 4)
/// Resistor ladder: R6=6.8K, R10=20K, R14=20K, R15=62K
/// Idle (no press) reads ~45. Need to discover button ADC values.
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
        return bk.armino.adc.read(14) catch 45; // channel 14 = P12
    }
};

pub const button_group_spec = struct {
    pub const Driver = AdcReader;
    /// Calibrated ranges on ADC14 (P12), BK7258 V3.2 EVB
    /// Measured values: K3=1477, K4=2903, K5=4438, idle=7652
    pub const ranges = &[_]@import("hal").button_group.Range{
        .{ .id = 0, .min = 1200, .max = 1800 },  // K3 = Do  (~1477)
        .{ .id = 1, .min = 2500, .max = 3300 },  // K4 = Re  (~2903)
        .{ .id = 2, .min = 4000, .max = 4900 },  // K5 = Mi  (~4438)
        .{ .id = 3, .min = 5500, .max = 6500 },  // K6 = Fa  (estimated ~6000)
    };
    pub const ref_value: u16 = 7650;
    pub const ref_tolerance: u16 = 500;
    pub const meta = .{ .id = "buttons.adc" };
};
