//! Korvo-2 V3 Board Implementation for ADC Button Example
//!
//! Hardware:
//! - 6 ADC buttons on ADC1 Channel 4

const std = @import("std");
const idf = @import("esp");
const hal = @import("hal");

// Platform primitives
pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.sal.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// Hardware parameters from lib/esp/boards
const hw_params = idf.boards.korvo2_v3;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
    pub const adc_channel: idf.adc.AdcChannel = @enumFromInt(hw_params.adc_channel);
};

// ============================================================================
// RTC Driver (required by hal.Board)
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// ButtonGroup Driver (ADC reader)
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
        std.log.info("AdcReader: ADC1 Channel {} initialized", .{@intFromEnum(Hardware.adc_channel)});

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
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = .{ .id = "rtc" };
};

/// Button group spec with ADC ranges
/// Calibrated for Korvo-2 V3.1 board
pub const button_group_spec = struct {
    pub const Driver = AdcReader;

    /// ADC value ranges (12-bit raw values)
    pub const ranges = &[_]hal.button_group.Range{
        .{ .id = 0, .min = 250, .max = 600 }, // vol_up
        .{ .id = 1, .min = 750, .max = 1100 }, // vol_down
        .{ .id = 2, .min = 1110, .max = 1500 }, // set
        .{ .id = 3, .min = 1510, .max = 2100 }, // play
        .{ .id = 4, .min = 2110, .max = 2550 }, // mute
        .{ .id = 5, .min = 2650, .max = 3100 }, // rec
    };

    pub const ref_value: u16 = 4095;
    pub const ref_tolerance: u16 = 500;

    pub const meta = .{ .id = "buttons.adc" };
};
