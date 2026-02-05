//! Hardware Definition & Drivers: 立创实战派 ESP32-S3 (LiChuang SZP)
//!
//! This file defines hardware configuration and provides pre-configured drivers
//! for the LiChuang ShiZhanPai (实战派) ESP32-S3 development board.
//!
//! Key features:
//! - ESP32-S3 with 16MB Flash, 8MB Octal PSRAM
//! - ES7210 (4-ch ADC) + ES8311 (DAC) audio codec
//! - PCA9557 I2C GPIO expander (PA_EN, LCD_CS, DVP_PWDN)
//! - QMI8658 6-axis IMU
//! - 320x240 SPI LCD
//! - MicroSD card slot
//!
//! Usage:
//!   const board = @import("esp").boards.lichuang_szp;
//!   pub const ButtonDriver = board.BootButtonDriver;
//!   pub const WifiDriver = board.WifiDriver;

const std = @import("std");
const idf = @import("idf");
const impl = @import("impl");
const hal = @import("hal");

// ============================================================================
// Board Identification
// ============================================================================

/// Board name
pub const name = "LiChuang-SZP-ESP32S3";

/// Serial port for flashing (USB-JTAG built-in)
pub const serial_port = "/dev/cu.usbmodem1101";

// ============================================================================
// WiFi Configuration
// ============================================================================

/// WiFi driver implementation
pub const wifi = impl.wifi;
pub const WifiDriver = wifi.WifiDriver;

/// WiFi spec for HAL
pub const wifi_spec = wifi.wifi_spec;

// ============================================================================
// Net Configuration
// ============================================================================

/// Network interface driver implementation
pub const net = impl.net;
pub const NetDriver = net.NetDriver;

/// Net spec for HAL
pub const net_spec = net.net_spec;

// ============================================================================
// Crypto Configuration
// ============================================================================

/// Crypto implementation (mbedTLS-based)
pub const crypto = impl.crypto.Suite;

// ============================================================================
// I2C Configuration
// ============================================================================

/// I2C SDA GPIO
pub const i2c_sda: u8 = 1;

/// I2C SCL GPIO
pub const i2c_scl: u8 = 2;

/// I2C frequency (Hz)
pub const i2c_freq_hz: u32 = 100_000;

/// Module-level I2C initialization state (shared between AudioSystem and PaSwitchDriver)
var i2c_initialized: bool = false;

// ============================================================================
// I2S Audio Configuration
// ============================================================================

/// Audio sample rate (Hz)
pub const sample_rate: u32 = 16000;

/// I2S port
pub const i2s_port: u8 = 0;

/// I2S pins
pub const i2s_mclk: u8 = 38;
pub const i2s_bclk: u8 = 14;
pub const i2s_ws: u8 = 13;
pub const i2s_dout: u8 = 45; // Speaker output (ES8311)
pub const i2s_din: u8 = 12; // Mic input (ES7210)

// ============================================================================
// Audio Codec I2C Addresses
// ============================================================================

/// ES8311 DAC I2C address
pub const es8311_addr: u8 = 0x18;

/// ES7210 ADC I2C address
pub const es7210_addr: u8 = 0x41;

// ============================================================================
// PCA9557 GPIO Expander Configuration
// ============================================================================

/// PCA9557 I2C address
pub const pca9557_addr: u7 = 0x19;

/// PCA9557 pin assignments
pub const pca9557_lcd_cs: u8 = 0; // IO0: LCD chip select
pub const pca9557_pa_en: u8 = 1; // IO1: Power amplifier enable
pub const pca9557_dvp_pwdn: u8 = 2; // IO2: Camera power down

// ============================================================================
// QMI8658 IMU Configuration
// ============================================================================

/// QMI8658 I2C address
pub const qmi8658_addr: u7 = 0x6A;

// ============================================================================
// LCD Configuration (SPI)
// ============================================================================

/// LCD resolution
pub const lcd_width: u16 = 320;
pub const lcd_height: u16 = 240;

/// LCD SPI pins
pub const lcd_mosi: u8 = 40;
pub const lcd_clk: u8 = 41;
pub const lcd_dc: u8 = 39;
pub const lcd_backlight: u8 = 42;

// ============================================================================
// SD Card Configuration (SDMMC)
// ============================================================================

/// SD card pins
pub const sd_cmd: u8 = 48;
pub const sd_clk: u8 = 47;
pub const sd_dat0: u8 = 21;

// ============================================================================
// GPIO Definitions
// ============================================================================

/// BOOT button GPIO
pub const boot_button_gpio: u8 = 0;

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
// C Helper Functions (from lib/esp/idf)
// ============================================================================

extern fn i2c_helper_init(sda: c_int, scl: c_int, freq_hz: u32, port: c_int) c_int;
extern fn i2c_helper_deinit() void;
extern fn i2c_helper_write(addr: u8, buf: [*]const u8, len: usize, timeout_ms: u32) c_int;
extern fn i2c_helper_write_read(addr: u8, write_buf: [*]const u8, write_len: usize, read_buf: [*]u8, read_len: usize, timeout_ms: u32) c_int;

extern fn i2s_helper_init_std_duplex(port: c_int, sample_rate_arg: u32, bits_per_sample: c_int, bclk_pin: c_int, ws_pin: c_int, din_pin: c_int, dout_pin: c_int, mclk_pin: c_int) c_int;
extern fn i2s_helper_init_full_duplex(port: c_int, sample_rate_arg: u32, rx_channels: c_int, bits_per_sample: c_int, bclk_pin: c_int, ws_pin: c_int, din_pin: c_int, dout_pin: c_int, mclk_pin: c_int) c_int;
extern fn i2s_helper_deinit(port: c_int) c_int;
extern fn i2s_helper_enable_rx(port: c_int) c_int;
extern fn i2s_helper_enable_tx(port: c_int) c_int;
extern fn i2s_helper_read(port: c_int, buffer: [*]u8, buffer_size: usize, bytes_read: *usize, timeout_ms: u32) c_int;
extern fn i2s_helper_write(port: c_int, buffer: [*]const u8, buffer_size: usize, bytes_written: *usize, timeout_ms: u32) c_int;

const AecHandle = opaque {};
extern fn aec_helper_create(input_format: [*:0]const u8, filter_length: c_int, aec_type: c_int, mode: c_int) ?*AecHandle;
extern fn aec_helper_process(handle: *AecHandle, indata: [*]const i16, outdata: [*]i16) c_int;
extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;

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
// PCA9557 Helper Functions
// ============================================================================

const PCA9557_OUTPUT_PORT: u8 = 0x01;
const PCA9557_CONFIG_PORT: u8 = 0x03;

fn pca9557Write(reg: u8, val: u8) void {
    const buf = [_]u8{ reg, val };
    _ = i2c_helper_write(pca9557_addr, &buf, 2, 100);
}

fn pca9557Read(reg: u8) u8 {
    var val: [1]u8 = undefined;
    _ = i2c_helper_write_read(pca9557_addr, &[_]u8{reg}, 1, &val, 1, 100);
    return val[0];
}

// ============================================================================
// PA Switch Driver (via PCA9557)
// ============================================================================

pub const PaSwitchDriver = struct {
    const Self = @This();

    is_on: bool = false,
    i2c_initialized_here: bool = false,
    output_cache: u8 = 0x05, // Default: DVP_PWDN=1, PA_EN=0, LCD_CS=1

    /// Initialize PA switch driver
    /// Automatically detects if I2C is already initialized (by AudioSystem or idf.I2c)
    pub fn init() !Self {
        var self = Self{};

        // Check module-level I2C state - skip init if already done by our code
        if (!i2c_initialized) {
            // Try to communicate with PCA9557 first to detect if I2C is already working
            // (e.g., initialized by idf.I2c in speaker_test)
            var test_val: [1]u8 = undefined;
            const probe_result = i2c_helper_write_read(pca9557_addr, &[_]u8{PCA9557_CONFIG_PORT}, 1, &test_val, 1, 100);

            if (probe_result != 0) {
                // I2C not working, initialize it ourselves
                if (i2c_helper_init(i2c_sda, i2c_scl, i2c_freq_hz, 0) != 0) {
                    return error.I2cInitFailed;
                }
                self.i2c_initialized_here = true;
            }
            i2c_initialized = true;
        }

        // Configure PCA9557: IO0-2 as outputs (0 = output)
        pca9557Write(PCA9557_CONFIG_PORT, 0xF8);

        // Read current output state and update cache
        self.output_cache = pca9557Read(PCA9557_OUTPUT_PORT);

        log.info("PaSwitchDriver: PCA9557 @ 0x{x} initialized", .{pca9557_addr});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.is_on) self.off() catch |err| log.warn("PA off failed in deinit: {}", .{err});
        if (self.i2c_initialized_here) {
            i2c_helper_deinit();
            i2c_initialized = false;
        }
    }

    pub fn on(self: *Self) !void {
        self.output_cache |= (1 << pca9557_pa_en);
        pca9557Write(PCA9557_OUTPUT_PORT, self.output_cache);
        self.is_on = true;
        log.info("PA enabled", .{});
    }

    pub fn off(self: *Self) !void {
        self.output_cache &= ~@as(u8, 1 << pca9557_pa_en);
        pca9557Write(PCA9557_OUTPUT_PORT, self.output_cache);
        self.is_on = false;
    }

    pub fn isOn(self: *Self) bool {
        return self.is_on;
    }
};

// ============================================================================
// LCD Backlight Driver (as LED substitute)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();
    pub const Color = hal.Color;

    const gpio = idf.gpio;

    initialized: bool = false,
    brightness: u8 = 0,

    pub fn init() !Self {
        try gpio.configOutput(lcd_backlight);
        try gpio.setLevel(lcd_backlight, 0);
        log.info("LedDriver: LCD backlight @ GPIO{} initialized", .{lcd_backlight});
        return Self{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            gpio.setLevel(lcd_backlight, 0) catch |err| log.warn("LCD backlight off failed: {}", .{err});
            self.initialized = false;
        }
    }

    /// Set pixel color - maps brightness to backlight on/off
    pub fn setPixel(self: *Self, index: u32, color: Color) void {
        if (index > 0 or !self.initialized) return;

        const brightness = @max(color.r, @max(color.g, color.b));
        self.brightness = brightness;

        // Simple on/off control (threshold at 30)
        const level: u1 = if (brightness >= 30) 1 else 0;
        gpio.setLevel(lcd_backlight, level) catch {};
    }

    pub fn getPixelCount(_: *Self) u32 {
        return 1;
    }

    pub fn refresh(_: *Self) void {
        // No-op: GPIO updates are synchronous
    }

    pub fn clear(self: *Self) void {
        if (self.initialized) {
            gpio.setLevel(lcd_backlight, 0) catch {};
            self.brightness = 0;
        }
    }

    /// Set backlight directly
    pub fn setBacklight(self: *Self, on: bool) void {
        if (self.initialized) {
            gpio.setLevel(lcd_backlight, if (on) 1 else 0) catch {};
            self.brightness = if (on) 255 else 0;
        }
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
// ES8311 Codec (DAC - Speaker)
// ============================================================================

const ES8311_RESET: u8 = 0x00;
const ES8311_CLK_MGR_01: u8 = 0x01;
const ES8311_CLK_MGR_02: u8 = 0x02;
const ES8311_CLK_MGR_03: u8 = 0x03;
const ES8311_CLK_MGR_04: u8 = 0x04;
const ES8311_CLK_MGR_05: u8 = 0x05;
const ES8311_CLK_MGR_06: u8 = 0x06;
const ES8311_SDP_IN: u8 = 0x09;
const ES8311_SDP_OUT: u8 = 0x0A;
const ES8311_SYS_0B: u8 = 0x0B;
const ES8311_SYS_0C: u8 = 0x0C;
const ES8311_SYS_0D: u8 = 0x0D;
const ES8311_SYS_0E: u8 = 0x0E;
const ES8311_SYS_10: u8 = 0x10;
const ES8311_SYS_11: u8 = 0x11;
const ES8311_SYS_12: u8 = 0x12;
const ES8311_SYS_14: u8 = 0x14;
const ES8311_ADC_15: u8 = 0x15;
const ES8311_ADC_16: u8 = 0x16;
const ES8311_ADC_17: u8 = 0x17;
const ES8311_DAC_32: u8 = 0x32;
const ES8311_DAC_37: u8 = 0x37;
const ES8311_GPIO_44: u8 = 0x44;
const ES8311_GP_45: u8 = 0x45;

fn es8311Write(reg: u8, val: u8) void {
    const buf = [_]u8{ reg, val };
    _ = i2c_helper_write(es8311_addr, &buf, 2, 100);
}

fn es8311Read(reg: u8) u8 {
    var val: [1]u8 = undefined;
    _ = i2c_helper_write_read(es8311_addr, &[_]u8{reg}, 1, &val, 1, 100);
    return val[0];
}

fn es8311Init() void {
    es8311Write(ES8311_GPIO_44, 0x08);
    es8311Write(ES8311_GPIO_44, 0x08);
    es8311Write(ES8311_CLK_MGR_01, 0x30);
    es8311Write(ES8311_CLK_MGR_02, 0x00);
    es8311Write(ES8311_CLK_MGR_03, 0x10);
    es8311Write(ES8311_ADC_16, 0x24);
    es8311Write(ES8311_CLK_MGR_04, 0x10);
    es8311Write(ES8311_CLK_MGR_05, 0x00);
    es8311Write(ES8311_SYS_0B, 0x00);
    es8311Write(ES8311_SYS_0C, 0x00);
    es8311Write(ES8311_SYS_10, 0x1F);
    es8311Write(ES8311_SYS_11, 0x7F);
    es8311Write(ES8311_RESET, 0x80);

    var regv = es8311Read(ES8311_RESET);
    regv &= 0xBF;
    es8311Write(ES8311_RESET, regv);

    regv = 0x3F & 0x7F;
    es8311Write(ES8311_CLK_MGR_01, regv);

    regv = es8311Read(ES8311_CLK_MGR_06);
    regv &= ~@as(u8, 0x20);
    es8311Write(ES8311_CLK_MGR_06, regv);

    es8311Write(ES8311_SYS_0D, 0x10);
    es8311Write(ES8311_ADC_17, 0xBF);
    es8311Write(ES8311_GPIO_44, 0x58);
}

fn es8311Start() void {
    var regv: u8 = 0x80;
    es8311Write(ES8311_RESET, regv);
    regv = 0x3F & 0x7F;
    es8311Write(ES8311_CLK_MGR_01, regv);

    var dac_iface = es8311Read(ES8311_SDP_IN);
    var adc_iface = es8311Read(ES8311_SDP_OUT);
    dac_iface &= 0xBF;
    adc_iface &= 0xBF;
    dac_iface &= ~@as(u8, 0x40);
    adc_iface &= ~@as(u8, 0x40);
    es8311Write(ES8311_SDP_IN, dac_iface);
    es8311Write(ES8311_SDP_OUT, adc_iface);

    es8311Write(ES8311_ADC_17, 0xBF);
    es8311Write(ES8311_SYS_0E, 0x02);
    es8311Write(ES8311_SYS_12, 0x00);
    es8311Write(ES8311_SYS_14, 0x1A);

    regv = es8311Read(ES8311_SYS_14);
    regv &= ~@as(u8, 0x40);
    es8311Write(ES8311_SYS_14, regv);

    es8311Write(ES8311_SYS_0D, 0x01);
    es8311Write(ES8311_ADC_15, 0x40);
    es8311Write(ES8311_DAC_37, 0x08);
    es8311Write(ES8311_GP_45, 0x00);
}

fn es8311SetVolume(vol: u8) void {
    es8311Write(ES8311_DAC_32, vol);
}

// ============================================================================
// ES7210 Codec (ADC - Microphone)
// ============================================================================

const ES7210_RESET: u8 = 0x00;
const ES7210_CLK_OFF: u8 = 0x01;
const ES7210_MAIN_CLK: u8 = 0x02;
const ES7210_LRCK_DIV_H: u8 = 0x04;
const ES7210_LRCK_DIV_L: u8 = 0x05;
const ES7210_POWER_DOWN: u8 = 0x06;
const ES7210_OSR: u8 = 0x07;
const ES7210_MODE_CFG: u8 = 0x08;
const ES7210_TIME_CTL0: u8 = 0x09;
const ES7210_TIME_CTL1: u8 = 0x0A;
const ES7210_SDP_IF1: u8 = 0x11;
const ES7210_SDP_IF2: u8 = 0x12;
const ES7210_ADC34_MUTE: u8 = 0x14;
const ES7210_ADC12_MUTE: u8 = 0x15;
const ES7210_ADC34_HPF2: u8 = 0x20;
const ES7210_ADC34_HPF1: u8 = 0x21;
const ES7210_ADC12_HPF1: u8 = 0x22;
const ES7210_ADC12_HPF2: u8 = 0x23;
const ES7210_ANALOG: u8 = 0x40;
const ES7210_MIC12_BIAS: u8 = 0x41;
const ES7210_MIC34_BIAS: u8 = 0x42;
const ES7210_MIC1_GAIN: u8 = 0x43;
const ES7210_MIC2_GAIN: u8 = 0x44;
const ES7210_MIC3_GAIN: u8 = 0x45;
const ES7210_MIC4_GAIN: u8 = 0x46;
const ES7210_MIC1_PWR: u8 = 0x47;
const ES7210_MIC2_PWR: u8 = 0x48;
const ES7210_MIC3_PWR: u8 = 0x49;
const ES7210_MIC4_PWR: u8 = 0x4A;
const ES7210_MIC12_PWR: u8 = 0x4B;
const ES7210_MIC34_PWR: u8 = 0x4C;

fn es7210Write(reg: u8, val: u8) void {
    const buf = [_]u8{ reg, val };
    _ = i2c_helper_write(es7210_addr, &buf, 2, 100);
}

fn es7210Read(reg: u8) u8 {
    var val: [1]u8 = undefined;
    _ = i2c_helper_write_read(es7210_addr, &[_]u8{reg}, 1, &val, 1, 100);
    return val[0];
}

fn es7210Update(reg: u8, mask: u8, val: u8) void {
    var regv = es7210Read(reg);
    regv = (regv & ~mask) | (val & mask);
    es7210Write(reg, regv);
}

fn es7210Init() void {
    es7210Write(ES7210_RESET, 0xFF);
    idf.time.sleepMs(10);
    es7210Write(ES7210_RESET, 0x41);

    es7210Write(ES7210_CLK_OFF, 0x3F);
    es7210Write(ES7210_TIME_CTL0, 0x30);
    es7210Write(ES7210_TIME_CTL1, 0x30);

    es7210Write(ES7210_ADC12_HPF2, 0x2A);
    es7210Write(ES7210_ADC12_HPF1, 0x0A);
    es7210Write(ES7210_ADC34_HPF2, 0x0A);
    es7210Write(ES7210_ADC34_HPF1, 0x2A);

    es7210Write(ES7210_ADC12_MUTE, 0x00);
    es7210Write(ES7210_ADC34_MUTE, 0x00);

    es7210Update(ES7210_MODE_CFG, 0x01, 0x00);

    es7210Write(ES7210_ANALOG, 0x43);
    es7210Write(ES7210_MIC12_BIAS, 0x70);
    es7210Write(ES7210_MIC34_BIAS, 0x70);
    es7210Write(ES7210_OSR, 0x20);

    es7210Write(ES7210_MAIN_CLK, 0xC1);
    es7210Write(ES7210_LRCK_DIV_H, 0x02);
    es7210Write(ES7210_LRCK_DIV_L, 0x00);

    // 按官方顺序设置增益
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x00);
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x00);
    es7210Update(ES7210_MIC4_GAIN, 0x10, 0x00);

    es7210Write(ES7210_MIC12_PWR, 0xFF);
    es7210Write(ES7210_MIC34_PWR, 0xFF);

    // MIC1/2 (24dB，和官方一致)
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC1_GAIN, 0x0F, 0x08); // 24dB
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC2_GAIN, 0x0F, 0x08); // 24dB

    // MIC3/REF
    es7210Update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210Write(ES7210_MIC34_PWR, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC3_GAIN, 0x0F, 0x08); // 24dB

    es7210Write(ES7210_SDP_IF2, 0x02);

    var adc_iface = es7210Read(ES7210_SDP_IF1);
    adc_iface &= 0x1C;
    adc_iface |= 0x00; // 24-bit mode
    adc_iface |= 0x60; // PCM mode B
    es7210Write(ES7210_SDP_IF1, adc_iface);

    es7210Write(ES7210_ANALOG, 0x43);
    es7210Write(ES7210_RESET, 0x71);
    es7210Write(ES7210_RESET, 0x41);
}

fn es7210Start() void {
    es7210Write(ES7210_CLK_OFF, 0x20);
    es7210Write(ES7210_POWER_DOWN, 0x00);
    es7210Write(ES7210_ANALOG, 0x43);
    es7210Write(ES7210_MIC1_PWR, 0x08);
    es7210Write(ES7210_MIC2_PWR, 0x08);
    es7210Write(ES7210_MIC3_PWR, 0x08);
    es7210Write(ES7210_MIC4_PWR, 0x08);

    // 按官方顺序设置增益
    // 1. 先清零所有增益的 PGA 位
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x00);
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x00);
    es7210Update(ES7210_MIC4_GAIN, 0x10, 0x00);

    // 2. 关闭电源
    es7210Write(ES7210_MIC12_PWR, 0xFF);
    es7210Write(ES7210_MIC34_PWR, 0xFF);

    // 3. MIC1: 使能时钟，打开电源，设置增益 (24dB，和官方一致)
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00); // MIC1/2 时钟
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x10); // PGA +3dB
    es7210Update(ES7210_MIC1_GAIN, 0x0F, 0x08); // 24dB (官方默认)

    // 4. MIC2: 同上
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC2_GAIN, 0x0F, 0x08); // 24dB

    // 5. MIC3/REF: 使能时钟，打开电源，设置增益
    es7210Update(ES7210_CLK_OFF, 0x15, 0x00); // MIC3/4 时钟
    es7210Write(ES7210_MIC34_PWR, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC3_GAIN, 0x0F, 0x08); // 24dB

    es7210Write(ES7210_SDP_IF2, 0x02);
}

// ============================================================================
// Audio System (Unified Mic + Speaker with AEC)
// ============================================================================

/// AudioSystem manages the complete audio subsystem for LiChuang SZP:
/// - ES7210 ADC (microphone)
/// - ES8311 DAC (speaker)
/// - I2S duplex for audio data
/// - AEC (Acoustic Echo Cancellation)
///
/// Usage:
///   var audio = try AudioSystem.init();
///   defer audio.deinit();
///
///   const samples = try audio.readMic(&buffer);
///   try audio.writeSpeaker(&output);
pub const AudioSystem = struct {
    const Self = @This();

    initialized: bool = false,
    aec_handle: ?*AecHandle = null,
    aec_frame_size: usize = 256,

    // Buffers allocated in PSRAM
    raw_buffer_32: ?[]i32 = null,
    aec_input: ?[]i16 = null,
    aec_output: ?[]i16 = null,
    tx_buffer_32: ?[]i32 = null,

    /// Initialize the audio system: I2C, I2S, codecs, and AEC
    pub fn init() !Self {
        var self = Self{};

        log.info("AudioSystem: Init I2C (SDA={}, SCL={})", .{ i2c_sda, i2c_scl });
        if (i2c_helper_init(i2c_sda, i2c_scl, i2c_freq_hz, 0) != 0) {
            return error.I2cInitFailed;
        }
        i2c_initialized = true;
        errdefer {
            i2c_helper_deinit();
            i2c_initialized = false;
        }

        log.info("AudioSystem: Init ES8311 (DAC @ 0x{x})", .{es8311_addr});
        es8311Init();

        log.info("AudioSystem: Init ES7210 (ADC @ 0x{x})", .{es7210_addr});
        es7210Init();

        log.info("AudioSystem: Init I2S STD duplex (MCLK={}, BCLK={}, WS={}, DIN={}, DOUT={})", .{
            i2s_mclk, i2s_bclk, i2s_ws, i2s_din, i2s_dout,
        });
        // Use STD mode (32-bit stereo)
        if (i2s_helper_init_std_duplex(i2s_port, sample_rate, 32, i2s_bclk, i2s_ws, i2s_din, i2s_dout, i2s_mclk) != 0) {
            return error.I2sInitFailed;
        }
        errdefer _ = i2s_helper_deinit(i2s_port);

        _ = i2s_helper_enable_rx(i2s_port);
        _ = i2s_helper_enable_tx(i2s_port);

        log.info("AudioSystem: Start ES8311", .{});
        es8311Start();
        es8311SetVolume(220);

        idf.time.sleepMs(10);

        log.info("AudioSystem: Start ES7210", .{});
        es7210Start();

        log.info("AudioSystem: Init AEC", .{});
        // AEC format: "RM" = Reference first, Mic second
        // We extract data from I2S and repack as RM format in readMic()
        // type=1 (AFE_TYPE_VC), mode=0 (AFE_MODE_LOW_COST), filter_length=2
        self.aec_handle = aec_helper_create("RM", 2, 1, 0);
        if (self.aec_handle == null) {
            return error.AecInitFailed;
        }
        errdefer if (self.aec_handle) |h| aec_helper_destroy(h);

        self.aec_frame_size = @intCast(aec_helper_get_chunksize(self.aec_handle.?));
        const total_ch: usize = @intCast(aec_helper_get_total_channels(self.aec_handle.?));
        log.info("AudioSystem: AEC frame={}, ch={}", .{ self.aec_frame_size, total_ch });

        // Allocate buffers in PSRAM
        const allocator = idf.heap.psram;

        self.raw_buffer_32 = allocator.alloc(i32, self.aec_frame_size * 2) catch {
            log.err("Failed to alloc raw_buffer", .{});
            return error.OutOfMemory;
        };
        errdefer if (self.raw_buffer_32) |b| allocator.free(b);

        self.aec_input = allocator.alloc(i16, self.aec_frame_size * total_ch) catch {
            log.err("Failed to alloc aec_input", .{});
            return error.OutOfMemory;
        };
        errdefer if (self.aec_input) |b| allocator.free(b);

        // AEC output needs 16-byte alignment
        self.aec_output = allocator.alignedAlloc(i16, .@"16", self.aec_frame_size) catch {
            log.err("Failed to alloc aec_output", .{});
            return error.OutOfMemory;
        };
        errdefer if (self.aec_output) |b| allocator.free(b);

        self.tx_buffer_32 = allocator.alloc(i32, self.aec_frame_size * 2) catch {
            log.err("Failed to alloc tx_buffer", .{});
            return error.OutOfMemory;
        };

        self.initialized = true;
        log.info("AudioSystem: Ready!", .{});
        return self;
    }

    /// Deinitialize the audio system and free all resources
    pub fn deinit(self: *Self) void {
        if (!self.initialized) return;

        const allocator = idf.heap.psram;
        if (self.aec_handle) |h| {
            aec_helper_destroy(h);
            self.aec_handle = null;
        }
        if (self.raw_buffer_32) |b| allocator.free(b);
        if (self.aec_input) |b| allocator.free(b);
        if (self.aec_output) |b| allocator.free(b);
        if (self.tx_buffer_32) |b| allocator.free(b);
        self.raw_buffer_32 = null;
        self.aec_input = null;
        self.aec_output = null;
        self.tx_buffer_32 = null;
        _ = i2s_helper_deinit(i2s_port);
        i2c_helper_deinit();
        i2c_initialized = false;
        self.initialized = false;
        log.info("AudioSystem: Deinitialized", .{});
    }

    // ========================================================================
    // Microphone Operations (with AEC)
    // ========================================================================

    /// Read AEC-processed audio from microphone
    /// Returns number of samples read
    pub fn readMic(self: *Self, buffer: []i16) !usize {
        if (!self.initialized) return error.NotInitialized;

        const aec_handle = self.aec_handle orelse return error.NoAec;
        const raw_buf = self.raw_buffer_32 orelse return error.NoBuffer;
        const aec_in = self.aec_input orelse return error.NoBuffer;
        const aec_out = self.aec_output orelse return error.NoBuffer;
        const frame_size = self.aec_frame_size;

        const to_read = frame_size * 2 * @sizeOf(i32);
        var bytes_read: usize = 0;
        const raw_bytes = std.mem.sliceAsBytes(raw_buf[0 .. frame_size * 2]);
        const ret = i2s_helper_read(i2s_port, raw_bytes.ptr, to_read, &bytes_read, 1000);

        if (ret != 0 or bytes_read == 0) {
            return 0;
        }

        const frames_read = bytes_read / @sizeOf(i32) / 2;

        // Signal strength statistics (static, persists across calls)
        const S = struct {
            var count: u32 = 0;
            var max_mic: i32 = 0;
            var max_ref: i32 = 0;
            var max_out: i32 = 0;
        };

        // Extract MIC1 and REF - pack as "RM" (ref first, mic second)
        // LiChuang SZP I2S format: L[31:16] = mic1, L[15:0] = ref
        for (0..frames_read) |i| {
            const L = raw_buf[i * 2];
            const mic1: i16 = @truncate(L >> 16);
            const ref: i16 = @truncate(L & 0xFFFF);
            aec_in[i * 2 + 0] = ref; // Reference first
            aec_in[i * 2 + 1] = mic1; // Mic second

            if (@abs(mic1) > S.max_mic) S.max_mic = @abs(mic1);
            if (@abs(ref) > S.max_ref) S.max_ref = @abs(ref);
        }

        // Run AEC
        _ = aec_helper_process(aec_handle, aec_in.ptr, aec_out.ptr);

        const copy_len = @min(buffer.len, frames_read);
        // No software gain - rely on ES7210 hardware gain (0x1F = 40.5dB)
        for (0..copy_len) |i| {
            buffer[i] = aec_out[i];
            if (@abs(aec_out[i]) > S.max_out) S.max_out = @abs(aec_out[i]);
        }

        // Log every 64 frames (~1 second at 16kHz/256 frame size)
        S.count += 1;
        if (S.count >= 64) {
            log.info("Signal: mic={}, ref={}, out={}", .{ S.max_mic, S.max_ref, S.max_out });
            S.count = 0;
            S.max_mic = 0;
            S.max_ref = 0;
            S.max_out = 0;
        }

        return copy_len;
    }

    /// Get the AEC frame size (optimal read buffer size)
    pub fn getFrameSize(self: *const Self) usize {
        return self.aec_frame_size;
    }

    // ========================================================================
    // Speaker Operations
    // ========================================================================

    /// Write audio to speaker
    /// Returns number of samples written
    pub fn writeSpeaker(self: *Self, buffer: []const i16) !usize {
        if (!self.initialized) return error.NotInitialized;

        const tx_buf = self.tx_buffer_32 orelse return error.NoBuffer;
        const frame_size = self.aec_frame_size;
        const mono_samples = @min(buffer.len, frame_size);

        // Convert mono i16 to stereo i32 (shift to upper 16 bits for 32-bit I2S)
        for (0..mono_samples) |i| {
            const sample32: i32 = @as(i32, buffer[i]) << 16;
            tx_buf[i * 2] = sample32;
            tx_buf[i * 2 + 1] = sample32;
        }

        var bytes_written: usize = 0;
        const tx_bytes = std.mem.sliceAsBytes(tx_buf[0 .. mono_samples * 2]);
        _ = i2s_helper_write(i2s_port, tx_bytes.ptr, tx_bytes.len, &bytes_written, 1000);

        return bytes_written / 8;
    }

    /// Set speaker volume (0-255)
    pub fn setVolume(_: *Self, volume: u8) void {
        es8311SetVolume(volume);
    }
};

