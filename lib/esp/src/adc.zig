//! ADC (Analog-to-Digital Converter) and Temperature Sensor driver
//!
//! Example - ADC:
//! ```zig
//! const adc = idf.adc;
//!
//! var adc_unit = try adc.AdcOneshot.init(.adc1);
//! defer adc_unit.deinit();
//!
//! try adc_unit.configChannel(.channel_0, .{
//!     .atten = .db_12,
//!     .bitwidth = .bits_12,
//! });
//!
//! const raw = try adc_unit.read(.channel_0);
//! ```
//!
//! Example - Temperature Sensor:
//! ```zig
//! const adc = idf.adc;
//!
//! var temp = try adc.TempSensor.init(.{});
//! defer temp.deinit();
//!
//! try temp.enable();
//! const celsius = try temp.readCelsius();
//! ```

const std = @import("std");
const sys = @import("sys.zig");

const c = @cImport({
    @cInclude("esp_adc/adc_oneshot.h");
    @cInclude("driver/temperature_sensor.h");
});

// ============================================================================
// ADC
// ============================================================================

/// ADC unit
pub const AdcUnit = enum(c_int) {
    adc1 = 0,
    adc2 = 1,
};

/// ADC channel
pub const AdcChannel = enum(c_int) {
    channel_0 = 0,
    channel_1 = 1,
    channel_2 = 2,
    channel_3 = 3,
    channel_4 = 4,
    channel_5 = 5,
    channel_6 = 6,
    channel_7 = 7,
    channel_8 = 8,
    channel_9 = 9,
};

/// ADC attenuation
pub const AdcAtten = enum(c_int) {
    db_0 = 0, // 0-750mV
    db_2_5 = 1, // 0-1050mV
    db_6 = 2, // 0-1300mV
    db_12 = 3, // 0-2500mV (recommended for most use cases)
};

/// ADC bit width
pub const AdcBitwidth = enum(c_int) {
    default = 0,
    bits_9 = 9,
    bits_10 = 10,
    bits_11 = 11,
    bits_12 = 12,
    bits_13 = 13,
};

/// ADC channel configuration
pub const ChannelConfig = struct {
    atten: AdcAtten = .db_12,
    bitwidth: AdcBitwidth = .default,
};

/// ADC Oneshot mode wrapper
pub const AdcOneshot = struct {
    handle: c.adc_oneshot_unit_handle_t,

    pub fn init(unit: AdcUnit) !AdcOneshot {
        var init_config = std.mem.zeroes(c.adc_oneshot_unit_init_cfg_t);
        init_config.unit_id = @intFromEnum(unit);

        var handle: c.adc_oneshot_unit_handle_t = null;
        const err = c.adc_oneshot_new_unit(&init_config, &handle);
        try sys.espErrToZig(err);

        return AdcOneshot{ .handle = handle };
    }

    pub fn deinit(self: *AdcOneshot) void {
        _ = c.adc_oneshot_del_unit(self.handle);
        self.handle = null;
    }

    /// Configure ADC channel
    pub fn configChannel(self: AdcOneshot, channel: AdcChannel, config: ChannelConfig) !void {
        var chan_config = std.mem.zeroes(c.adc_oneshot_chan_cfg_t);
        chan_config.atten = @intFromEnum(config.atten);
        chan_config.bitwidth = @intFromEnum(config.bitwidth);

        const err = c.adc_oneshot_config_channel(self.handle, @intFromEnum(channel), &chan_config);
        try sys.espErrToZig(err);
    }

    /// Read raw ADC value
    pub fn read(self: AdcOneshot, channel: AdcChannel) !i32 {
        var raw: c_int = 0;
        const err = c.adc_oneshot_read(self.handle, @intFromEnum(channel), &raw);
        try sys.espErrToZig(err);
        return raw;
    }

    /// Read and convert to voltage (mV) - approximate
    pub fn readMillivolts(self: AdcOneshot, channel: AdcChannel, atten: AdcAtten) !u32 {
        const raw = try self.read(channel);
        // Approximate conversion based on attenuation
        // For accurate conversion, use ADC calibration
        const max_mv: u32 = switch (atten) {
            .db_0 => 750,
            .db_2_5 => 1050,
            .db_6 => 1300,
            .db_12 => 2500,
        };
        return @intCast(@as(u32, @intCast(raw)) * max_mv / 4095);
    }
};

// ============================================================================
// Temperature Sensor
// ============================================================================

/// Temperature sensor range
pub const TempRange = struct {
    min: i8 = -10,
    max: i8 = 80,
};

/// Temperature sensor configuration
pub const TempConfig = struct {
    range: TempRange = .{ .min = -10, .max = 80 },
    clk_src: u32 = 0, // Default clock source
};

/// Internal temperature sensor wrapper
pub const TempSensor = struct {
    handle: c.temperature_sensor_handle_t,

    pub fn init(config: TempConfig) !TempSensor {
        var temp_config = std.mem.zeroes(c.temperature_sensor_config_t);
        temp_config.range_min = config.range.min;
        temp_config.range_max = config.range.max;
        temp_config.clk_src = config.clk_src;

        var handle: c.temperature_sensor_handle_t = null;
        const err = c.temperature_sensor_install(&temp_config, &handle);
        try sys.espErrToZig(err);

        return TempSensor{ .handle = handle };
    }

    pub fn deinit(self: *TempSensor) void {
        _ = c.temperature_sensor_uninstall(self.handle);
        self.handle = null;
    }

    /// Enable temperature sensor
    pub fn enable(self: TempSensor) !void {
        const err = c.temperature_sensor_enable(self.handle);
        try sys.espErrToZig(err);
    }

    /// Disable temperature sensor
    pub fn disable(self: TempSensor) !void {
        const err = c.temperature_sensor_disable(self.handle);
        try sys.espErrToZig(err);
    }

    /// Read temperature in Celsius
    pub fn readCelsius(self: TempSensor) !f32 {
        var temp: f32 = 0;
        const err = c.temperature_sensor_get_celsius(self.handle, &temp);
        try sys.espErrToZig(err);
        return temp;
    }
};
