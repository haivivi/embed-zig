//! Korvo-2 V3 Board Configuration for ADC Piano
//!
//! Hardware:
//! - 4 ADC buttons on ADC1 Channel 4 (first 4 of 6)
//! - ES8311 mono DAC speaker via I2S + I2C
//! - PA enable GPIO

const std = @import("std");
const hal = @import("hal");
const esp = @import("esp");

const idf = esp.idf;
const board = esp.boards.korvo2_v3;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const sample_rate: u32 = board.sample_rate;
    pub const adc_channel: idf.adc.AdcChannel = @enumFromInt(board.adc_channel);
    pub const pa_enable_gpio: u8 = board.pa_gpio;
};

// ============================================================================
// Platform Primitives
// ============================================================================

pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}

// ============================================================================
// ADC Reader for Button Group
// ============================================================================

pub const AdcReader = struct {
    const Self = @This();

    adc_unit: ?idf.adc.AdcOneshot = null,
    initialized: bool = false,

    pub fn init() !Self {
        var self = Self{};
        self.adc_unit = try idf.adc.AdcOneshot.init(.adc1);
        errdefer {
            if (self.adc_unit) |*unit| unit.deinit();
        }
        try self.adc_unit.?.configChannel(Hardware.adc_channel, .{
            .atten = .db_12,
            .bitwidth = .bits_12,
        });
        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.adc_unit) |*unit| {
            unit.deinit();
            self.adc_unit = null;
        }
        self.initialized = false;
    }

    pub fn readRaw(self: *Self) u16 {
        if (self.adc_unit) |unit| {
            const raw = unit.read(Hardware.adc_channel) catch return 4095;
            return if (raw > 0) @intCast(raw) else 4095;
        }
        return 4095;
    }
};

// ============================================================================
// Drivers
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

/// ADC button ranges — first 4 buttons of the Korvo-2 V3 resistor ladder
/// Calibrated for 12-bit ADC with db_12 attenuation
pub const button_group_spec = struct {
    pub const Driver = AdcReader;

    pub const ranges = &[_]hal.button_group.Range{
        .{ .id = 0, .min = 250, .max = 600 }, // Do (was vol_up)
        .{ .id = 1, .min = 750, .max = 1100 }, // Re (was vol_down)
        .{ .id = 2, .min = 1110, .max = 1500 }, // Mi (was set)
        .{ .id = 3, .min = 1510, .max = 2100 }, // Fa (was play)
    };

    pub const ref_value: u16 = 4095;
    pub const ref_tolerance: u16 = 500;

    pub const meta = .{ .id = "buttons.adc" };
};
