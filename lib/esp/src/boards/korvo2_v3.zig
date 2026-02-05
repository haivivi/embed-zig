//! Hardware Definition & Drivers: ESP32-S3-Korvo-2 V3
//!
//! This file defines hardware configuration and provides pre-configured drivers
//! for the ESP32-S3-Korvo-2 V3 board.
//!
//! Usage:
//!   const board = @import("esp").boards.korvo2_v3;
//!
//!   // Audio (mic + speaker with AEC)
//!   var audio = try board.AudioSystem.init();
//!   defer audio.deinit();
//!   const samples = try audio.readMic(&buffer);
//!   try audio.writeSpeaker(&output);

const std = @import("std");
const idf = @import("idf");
const hal = @import("hal");
const drivers = @import("drivers");

// ============================================================================
// Board Identification
// ============================================================================

/// Board name
pub const name = "ESP32-S3-Korvo-2-V3";

/// Serial port for flashing
pub const serial_port = "/dev/cu.usbserial-120";

// ============================================================================
// Audio Configuration
// ============================================================================

/// Audio sample rate (Hz)
pub const sample_rate: u32 = 16000;

/// I2S port (shared for mic and speaker in duplex mode)
pub const i2s_port: u8 = 0;

/// I2S pins
pub const i2s_bclk: u8 = 9;
pub const i2s_ws: u8 = 45;
pub const i2s_din: u8 = 10; // Mic input (ES7210)
pub const i2s_dout: u8 = 8; // Speaker output (ES8311)
pub const i2s_mclk: u8 = 16;

/// ES8311 DAC I2C address
pub const es8311_addr: u8 = 0x18;

/// ES7210 ADC I2C address
pub const es7210_addr: u8 = 0x40;

/// PA (Power Amplifier) enable GPIO
pub const pa_gpio: u8 = 48;

// ============================================================================
// I2C Configuration
// ============================================================================

/// I2C SDA GPIO
pub const i2c_sda: u8 = 17;

/// I2C SCL GPIO
pub const i2c_scl: u8 = 18;

/// I2C frequency (Hz)
pub const i2c_freq_hz: u32 = 400_000;

/// TCA9554 GPIO expander I2C address
pub const tca9554_addr: u7 = 0x20;

// ============================================================================
// ADC Button Configuration
// ============================================================================

/// ADC unit for buttons
pub const adc_unit = 1; // ADC1

/// ADC channel for buttons (GPIO5)
pub const adc_channel = 4;

/// Number of ADC buttons
pub const num_buttons = 6;

/// Reference voltage (idle state) in mV
pub const ref_voltage_mv: u32 = 4095;

/// Reference tolerance (±mV)
pub const ref_tolerance_mv: u32 = 1000;

/// Button voltage range
pub const VoltageRange = struct {
    min_mv: u16,
    max_mv: u16,
};

/// Button voltage ranges (measured on Korvo-2 V3.1)
pub const button_voltage_ranges = [num_buttons]VoltageRange{
    .{ .min_mv = 250, .max_mv = 600 }, // Button 0: VOL+
    .{ .min_mv = 750, .max_mv = 1100 }, // Button 1: VOL-
    .{ .min_mv = 1110, .max_mv = 1500 }, // Button 2: SET
    .{ .min_mv = 1510, .max_mv = 2100 }, // Button 3: PLAY
    .{ .min_mv = 2110, .max_mv = 2550 }, // Button 4: MUTE
    .{ .min_mv = 2650, .max_mv = 3100 }, // Button 5: REC
};

/// Get button index from ADC value
pub fn buttonIndexFromAdc(adc_mv: u32) ?u8 {
    for (button_voltage_ranges, 0..) |range, i| {
        if (adc_mv >= range.min_mv and adc_mv <= range.max_mv) {
            return @intCast(i);
        }
    }
    return null;
}

/// Check if ADC value is in reference (idle) state
pub fn isIdle(adc_mv: u32) bool {
    const ref_min = ref_voltage_mv -| ref_tolerance_mv;
    return adc_mv >= ref_min;
}

// ============================================================================
// GPIO Definitions
// ============================================================================

/// BOOT button GPIO
pub const boot_button_gpio: u8 = 0;

// ============================================================================
// LED Configuration (via TCA9554 GPIO expander)
// ============================================================================

/// LED type: TCA9554 (not WS2812)
pub const led_type = .tca9554;

/// Red LED pin on TCA9554
pub const led_red_pin = 6;

/// Blue LED pin on TCA9554
pub const led_blue_pin = 7;

/// Number of LEDs (logical - for HAL compatibility)
pub const led_strip_count = 1;

/// Default brightness (0-255, but only on/off supported)
pub const led_strip_default_brightness = 128;

// ============================================================================
// Platform Helpers
// ============================================================================

pub const log = std.log.scoped(.board);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }
    pub fn getTimeMs() u64 {
        return idf.time.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
}

// ============================================================================
// Audio System (via generic audio_system module)
// ============================================================================

const audio_system = @import("../audio_system.zig");

/// AudioSystem manages the complete audio subsystem for Korvo-2 V3:
/// - ES7210 ADC (4-channel microphone)
/// - ES8311 DAC (mono speaker)
/// - I2S duplex for audio data
/// - AEC (Acoustic Echo Cancellation)
/// I2C is managed externally and passed to AudioSystem.init()
pub const AudioSystem = audio_system.AudioSystem(.{
    .i2s_port = i2s_port,
    .i2s_bclk = i2s_bclk,
    .i2s_ws = i2s_ws,
    .i2s_din = i2s_din,
    .i2s_dout = i2s_dout,
    .i2s_mclk = i2s_mclk,
    .sample_rate = sample_rate,
    .es8311_addr = es8311_addr,
    .es8311_volume = 150,
    .es7210_addr = es7210_addr,
    .mic_select = .{ .mic1 = true, .mic2 = true, .mic3 = true },
});

// ============================================================================
// TCA9554 GPIO Expander Driver (for LED)
// ============================================================================

/// TCA9554 GPIO expander driver type
const Tca9554Driver = drivers.Tca9554(*idf.I2c);

// ============================================================================
// RTC Driver
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.time.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// PA Switch Driver
// ============================================================================

pub const PaSwitchDriver = struct {
    const Self = @This();
    const gpio = idf.gpio;

    is_on: bool = false,

    /// Initialize PA switch driver
    /// Note: i2c parameter is for API compatibility with other boards (ignored here, uses direct GPIO)
    pub fn init(_: *idf.I2c) !Self {
        try gpio.configOutput(pa_gpio);
        try gpio.setLevel(pa_gpio, 0);
        return Self{ .is_on = false };
    }

    pub fn deinit(self: *Self) void {
        if (self.is_on) self.off() catch {};
        gpio.reset(pa_gpio) catch {};
    }

    pub fn on(self: *Self) !void {
        try gpio.setLevel(pa_gpio, 1);
        self.is_on = true;
        log.info("PA enabled", .{});
    }

    pub fn off(self: *Self) !void {
        try gpio.setLevel(pa_gpio, 0);
        self.is_on = false;
    }

    pub fn isOn(self: *Self) bool {
        return self.is_on;
    }
};

// ============================================================================
// Speaker Driver (standalone, without AEC)
// ============================================================================

/// ES8311 DAC driver type for standalone speaker
const Es8311Driver = drivers.Es8311(*idf.I2c);

/// ESP Speaker type using ES8311
const EspSpeaker = idf.Speaker(Es8311Driver);

/// Standalone speaker driver for speaker-only applications (no AEC/mic)
/// Uses external I2C and I2S instances for flexibility
pub const SpeakerDriver = struct {
    const Self = @This();

    dac: Es8311Driver = undefined,
    speaker: EspSpeaker = undefined,
    initialized: bool = false,

    pub fn init() !Self {
        return Self{};
    }

    /// Initialize speaker using shared I2S and I2C
    pub fn initWithShared(self: *Self, i2c: *idf.I2c, i2s: *idf.I2s) !void {
        if (self.initialized) return;

        // Initialize ES8311 DAC via shared I2C
        self.dac = Es8311Driver.init(i2c, .{
            .address = es8311_addr,
            .codec_mode = .dac_only,
        });

        try self.dac.open();
        errdefer self.dac.close() catch {};

        try self.dac.setSampleRate(sample_rate);

        // Initialize speaker using shared I2S
        self.speaker = try EspSpeaker.init(&self.dac, i2s, .{
            .initial_volume = 180,
        });
        errdefer self.speaker.deinit();

        log.info("SpeakerDriver: ES8311 + shared I2S initialized", .{});
        self.initialized = true;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.speaker.deinit();
            self.dac.close() catch {};
            self.initialized = false;
        }
    }

    pub fn write(self: *Self, buffer: []const i16) !usize {
        if (!self.initialized) return error.NotInitialized;
        return self.speaker.write(buffer);
    }

    pub fn setVolume(self: *Self, volume: u8) !void {
        if (!self.initialized) return error.NotInitialized;
        try self.speaker.setVolume(volume);
    }
};

// ============================================================================
// Boot Button Driver (GPIO0)
// ============================================================================

pub const BootButtonDriver = struct {
    const Self = @This();
    const gpio = idf.gpio;

    initialized: bool = false,

    pub fn init() !Self {
        try gpio.configInput(boot_button_gpio, true); // with pull-up
        log.info("BootButtonDriver: GPIO{} initialized", .{boot_button_gpio});
        return Self{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    /// Returns true if button is pressed (active low)
    pub fn isPressed(_: *const Self) bool {
        return idf.gpio.getLevel(boot_button_gpio) == 0;
    }
};

// ============================================================================
// ADC Button Driver (for ButtonGroup)
// ============================================================================

pub const AdcButtonDriver = struct {
    const Self = @This();

    initialized: bool = false,

    pub fn init() !Self {
        // ADC initialization happens lazily via idf.adc
        return Self{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    /// Read raw ADC value (for ButtonGroup polling)
    pub fn readRaw(_: *Self) u16 {
        // Use idf.adc to read the button ADC channel
        const raw = idf.adc.readRaw(adc_unit, adc_channel) catch 4095;
        return @intCast(raw);
    }
};

// ============================================================================
// TCA9554 LED Driver (Red/Blue LEDs via I2C GPIO expander)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();
    pub const Color = hal.Color;

    // Use TCA9554 driver's Pin enum for LED pins
    const Pin = drivers.Tca9554Pin;
    const RED_PIN: Pin = @enumFromInt(led_red_pin);
    const BLUE_PIN: Pin = @enumFromInt(led_blue_pin);

    initialized: bool = false,
    gpio: Tca9554Driver = undefined,

    /// Initialize with external I2C (managed by caller)
    pub fn init(i2c: *idf.I2c) !Self {
        var self = Self{};

        // Initialize TCA9554 GPIO expander driver
        self.gpio = Tca9554Driver.init(i2c, tca9554_addr);

        // Sync current state from device
        self.gpio.syncFromDevice() catch return error.GpioInitFailed;

        // Configure LED pins as outputs with initial high (LEDs off, active low)
        self.gpio.configureOutput(RED_PIN, .high) catch return error.GpioInitFailed;
        self.gpio.configureOutput(BLUE_PIN, .high) catch return error.GpioInitFailed;

        self.initialized = true;
        log.info("LedDriver: TCA9554 @ 0x{x} initialized via driver", .{tca9554_addr});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            // Turn off LEDs (set high = off)
            self.gpio.setHigh(RED_PIN) catch |err| log.warn("LedDriver deinit: failed to turn off red LED: {}", .{err});
            self.gpio.setHigh(BLUE_PIN) catch |err| log.warn("LedDriver deinit: failed to turn off blue LED: {}", .{err});
            // I2C is managed externally, don't deinit here
            self.initialized = false;
        }
    }

    /// Set pixel color (index 0 only, maps RGB to red/blue)
    pub fn setPixel(self: *Self, index: u32, color: Color) void {
        if (index > 0 or !self.initialized) return;

        const brightness = @max(color.r, @max(color.g, color.b));
        const threshold: u8 = 30;

        var red_on = false;
        var blue_on = false;

        if (brightness >= threshold) {
            if (color.r > color.b + 50) {
                red_on = true;
            } else if (color.b > color.r + 50) {
                blue_on = true;
            } else if (color.g > color.r and color.g > color.b) {
                // Green maps to blue
                blue_on = true;
            } else {
                // Default: both on (purple/white)
                red_on = true;
                blue_on = true;
            }
        }

        // Active low: low = on, high = off
        self.gpio.write(RED_PIN, if (red_on) .low else .high) catch |err| log.warn("LedDriver setPixel: red LED write failed: {}", .{err});
        self.gpio.write(BLUE_PIN, if (blue_on) .low else .high) catch |err| log.warn("LedDriver setPixel: blue LED write failed: {}", .{err});
    }

    pub fn getPixelCount(_: *Self) u32 {
        return 1;
    }

    pub fn refresh(_: *Self) void {
        // No-op: TCA9554 updates are synchronous
    }

    // Convenience methods
    pub fn setRed(self: *Self, on: bool) void {
        // Active low: low = on, high = off
        self.gpio.write(RED_PIN, if (on) .low else .high) catch |err| log.warn("LedDriver setRed: write failed: {}", .{err});
    }

    pub fn setBlue(self: *Self, on: bool) void {
        // Active low: low = on, high = off
        self.gpio.write(BLUE_PIN, if (on) .low else .high) catch |err| log.warn("LedDriver setBlue: write failed: {}", .{err});
    }

    pub fn off(self: *Self) void {
        // Both LEDs off (high = off)
        self.gpio.setHigh(RED_PIN) catch |err| log.warn("LedDriver off: red LED failed: {}", .{err});
        self.gpio.setHigh(BLUE_PIN) catch |err| log.warn("LedDriver off: blue LED failed: {}", .{err});
    }
};

// ============================================================================
// Temperature Sensor Driver (Internal)
// ============================================================================

pub const TempSensorDriver = struct {
    const Self = @This();

    sensor: idf.adc.TempSensor,
    enabled: bool = false,

    pub fn init() !Self {
        var sensor = try idf.adc.TempSensor.init(.{
            .range = .{ .min = -10, .max = 80 },
        });
        try sensor.enable();
        log.info("TempSensorDriver: Internal sensor initialized", .{});
        return Self{ .sensor = sensor, .enabled = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.enabled) {
            self.sensor.disable() catch {};
        }
        self.sensor.deinit();
    }

    pub fn enable(self: *Self) !void {
        if (!self.enabled) {
            try self.sensor.enable();
            self.enabled = true;
        }
    }

    pub fn disable(self: *Self) !void {
        if (self.enabled) {
            try self.sensor.disable();
            self.enabled = false;
        }
    }

    pub fn readCelsius(self: *Self) !f32 {
        if (!self.enabled) {
            try self.enable();
        }
        return self.sensor.readCelsius();
    }
};

// ============================================================================
// WiFi Driver
// ============================================================================

pub const WifiDriver = struct {
    const Self = @This();

    wifi: ?idf.Wifi = null,
    connected: bool = false,
    ip_address: ?[4]u8 = null,

    pub fn init() !Self {
        return Self{};
    }

    pub fn deinit(self: *Self) void {
        if (self.wifi) |*w| {
            w.disconnect();
            w.deinit();
        }
        self.wifi = null;
        self.connected = false;
        self.ip_address = null;
    }

    pub fn connect(self: *Self, ssid: []const u8, password: []const u8) !void {
        // Initialize WiFi if not already done
        if (self.wifi == null) {
            self.wifi = idf.Wifi.init() catch |err| {
                log.err("WiFi init failed: {}", .{err});
                return error.InitFailed;
            };
        }

        // Connect with sentinel-terminated strings
        var ssid_buf: [33:0]u8 = undefined;
        var pass_buf: [65:0]u8 = undefined;

        const ssid_len = @min(ssid.len, 32);
        const pass_len = @min(password.len, 64);

        @memcpy(ssid_buf[0..ssid_len], ssid[0..ssid_len]);
        ssid_buf[ssid_len] = 0;

        @memcpy(pass_buf[0..pass_len], password[0..pass_len]);
        pass_buf[pass_len] = 0;

        self.wifi.?.connect(.{
            .ssid = ssid_buf[0..ssid_len :0],
            .password = pass_buf[0..pass_len :0],
            .timeout_ms = 30000,
        }) catch |err| {
            log.err("WiFi connect failed: {}", .{err});
            return error.ConnectFailed;
        };

        self.connected = true;
        self.ip_address = self.wifi.?.getIpAddress();
        log.info("WiFi connected, IP: {}.{}.{}.{}", .{
            self.ip_address.?[0],
            self.ip_address.?[1],
            self.ip_address.?[2],
            self.ip_address.?[3],
        });
    }

    pub fn disconnect(self: *Self) void {
        if (self.wifi) |*w| {
            w.disconnect();
        }
        self.connected = false;
        self.ip_address = null;
    }

    pub fn isConnected(self: *const Self) bool {
        return self.connected;
    }

    pub fn getIpAddress(self: *const Self) ?[4]u8 {
        return self.ip_address;
    }

    pub fn getRssi(self: *const Self) ?i8 {
        if (self.wifi) |*w| {
            return w.getRssi();
        }
        return null;
    }

    pub fn getMac(self: *const Self) ?[6]u8 {
        if (self.wifi) |*w| {
            return w.getMac();
        }
        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "buttonIndexFromAdc" {
    try std.testing.expectEqual(@as(u8, 0), buttonIndexFromAdc(410).?);
    try std.testing.expectEqual(@as(u8, 1), buttonIndexFromAdc(922).?);
    try std.testing.expectEqual(@as(u8, 2), buttonIndexFromAdc(1275).?);
    try std.testing.expectEqual(@as(u8, 4), buttonIndexFromAdc(2312).?);
    try std.testing.expectEqual(@as(u8, 5), buttonIndexFromAdc(2852).?);
    try std.testing.expect(buttonIndexFromAdc(650) == null);
    try std.testing.expect(buttonIndexFromAdc(200) == null);
}

test "isIdle" {
    try std.testing.expect(isIdle(4095));
    try std.testing.expect(isIdle(3500));
    try std.testing.expect(!isIdle(2000));
    try std.testing.expect(!isIdle(500));
}
