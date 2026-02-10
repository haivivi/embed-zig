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
// Self-contained Speaker Driver (owns I2C + I2S internally)
// ============================================================================

pub const SelfContainedSpeakerDriver = struct {
    const Self = @This();

    i2c: ?idf.I2c = null,
    i2s: ?idf.I2s = null,
    inner: board.SpeakerDriver = undefined,
    initialized: bool = false,

    pub fn init() !Self {
        var self = Self{};

        // Init I2C bus
        self.i2c = idf.I2c.init(.{
            .port = 0,
            .sda = board.i2c_sda,
            .scl = board.i2c_scl,
            .freq_hz = 100_000,
        }) catch |err| {
            std.log.err("I2C init failed: {}", .{err});
            return error.InitFailed;
        };

        // Init I2S bus
        self.i2s = idf.I2s.init(.{
            .port = board.i2s_port,
            .bclk_pin = board.i2s_bclk,
            .ws_pin = board.i2s_ws,
            .dout_pin = board.i2s_dout,
            .mclk_pin = board.i2s_mclk,
            .sample_rate = board.sample_rate,
            .bits_per_sample = 16,
        }) catch |err| {
            std.log.err("I2S init failed: {}", .{err});
            if (self.i2c) |*i| i.deinit();
            return error.InitFailed;
        };

        // Init ES8311 speaker via shared I2C/I2S
        self.inner = board.SpeakerDriver.init() catch return error.InitFailed;
        self.inner.initWithShared(&self.i2c.?, &self.i2s.?) catch |err| {
            std.log.err("Speaker initWithShared failed: {}", .{err});
            if (self.i2s) |*s| s.deinit();
            if (self.i2c) |*i| i.deinit();
            return error.InitFailed;
        };

        self.initialized = true;
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.inner.deinit();
            if (self.i2s) |*s| s.deinit();
            if (self.i2c) |*i| i.deinit();
            self.initialized = false;
        }
    }

    pub fn write(self: *Self, buffer: []const i16) !usize {
        return self.inner.write(buffer);
    }

    pub fn setVolume(self: *Self, volume: u8) !void {
        try self.inner.setVolume(volume);
    }
};

// ============================================================================
// PA Switch (GPIO-based, no I2C needed)
// ============================================================================

pub const PaSwitchDriver = struct {
    const Self = @This();
    const gpio = idf.gpio;

    is_on: bool = false,

    pub fn init() !Self {
        try gpio.configOutput(board.pa_gpio);
        try gpio.setLevel(board.pa_gpio, 0);
        return Self{ .is_on = false };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_on) self.off() catch {};
        gpio.reset(board.pa_gpio) catch {};
    }

    pub fn on(self: *Self) !void {
        try gpio.setLevel(board.pa_gpio, 1);
        self.is_on = true;
        std.log.info("PA enabled", .{});
    }

    pub fn off(self: *Self) !void {
        try gpio.setLevel(board.pa_gpio, 0);
        self.is_on = false;
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
    pub const Driver = PaSwitchDriver;
    pub const meta = .{ .id = "switch.pa" };
};

pub const speaker_spec = struct {
    pub const Driver = SelfContainedSpeakerDriver;
    pub const meta = .{ .id = "speaker.es8311" };
    pub const config = hal.MonoSpeakerConfig{
        .sample_rate = Hardware.sample_rate,
    };
};

/// ADC button ranges — first 4 buttons of the Korvo-2 V3 resistor ladder
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
