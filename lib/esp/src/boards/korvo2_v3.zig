//! Hardware Definition & Drivers: ESP32-S3-Korvo-2 V3
//!
//! This file defines hardware configuration and provides pre-configured drivers
//! for the ESP32-S3-Korvo-2 V3 board.
//!
//! Usage:
//!   const board = @import("esp").boards.korvo2_v3;
//!   pub const MicDriver = board.MicDriver;
//!   pub const SpeakerDriver = board.SpeakerDriver;

const std = @import("std");
const idf = @import("idf");

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
// C Helper Functions (from lib/esp/idf)
// ============================================================================

extern fn i2c_helper_init(sda: c_int, scl: c_int, freq_hz: u32, port: c_int) c_int;
extern fn i2c_helper_deinit() void;
extern fn i2c_helper_write(addr: u8, buf: [*]const u8, len: usize, timeout_ms: u32) c_int;
extern fn i2c_helper_write_read(addr: u8, write_buf: [*]const u8, write_len: usize, read_buf: [*]u8, read_len: usize, timeout_ms: u32) c_int;

extern fn i2s_helper_init_std_duplex(port: c_int, sample_rate_arg: u32, bits_per_sample: c_int, bclk_pin: c_int, ws_pin: c_int, din_pin: c_int, dout_pin: c_int, mclk_pin: c_int) c_int;
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

    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        es7210Update(ES7210_MIC1_GAIN + i, 0x10, 0x00);
    }
    es7210Write(ES7210_MIC12_PWR, 0xFF);
    es7210Write(ES7210_MIC34_PWR, 0xFF);

    // MIC1
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC1_GAIN, 0x0F, 0x0A);

    // MIC2
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC2_GAIN, 0x0F, 0x0A);

    // MIC3/REF
    es7210Update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210Write(ES7210_MIC34_PWR, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC3_GAIN, 0x0F, 0x0A);

    es7210Write(ES7210_SDP_IF2, 0x02);

    var adc_iface = es7210Read(ES7210_SDP_IF1);
    adc_iface &= 0x1C;
    adc_iface |= 0x00;
    adc_iface |= 0x60;
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

    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        es7210Update(ES7210_MIC1_GAIN + i, 0x10, 0x00);
    }
    es7210Write(ES7210_MIC12_PWR, 0xFF);
    es7210Write(ES7210_MIC34_PWR, 0xFF);

    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC1_GAIN, 0x0F, 0x0A);

    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC2_GAIN, 0x0F, 0x0A);

    es7210Update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210Write(ES7210_MIC34_PWR, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC3_GAIN, 0x0F, 0x0A);

    es7210Write(ES7210_SDP_IF2, 0x02);
}

// ============================================================================
// Audio System (Global State)
// ============================================================================

var g_initialized: bool = false;
var g_aec_handle: ?*AecHandle = null;
var g_aec_frame_size: usize = 256;
var g_raw_buffer_32: ?[]i32 = null;
var g_aec_input: ?[]i16 = null;
var g_aec_output: ?[]i16 = null;
var g_tx_buffer_32: ?[]i32 = null;

fn initAudioSystem() !void {
    if (g_initialized) return;

    log.info("AudioSystem: Init I2C", .{});
    if (i2c_helper_init(i2c_sda, i2c_scl, i2c_freq_hz, 0) != 0) {
        return error.I2cInitFailed;
    }

    log.info("AudioSystem: Init ES8311", .{});
    es8311Init();

    log.info("AudioSystem: Init ES7210", .{});
    es7210Init();

    log.info("AudioSystem: Init I2S", .{});
    if (i2s_helper_init_std_duplex(i2s_port, sample_rate, 32, i2s_bclk, i2s_ws, i2s_din, i2s_dout, i2s_mclk) != 0) {
        return error.I2sInitFailed;
    }
    _ = i2s_helper_enable_rx(i2s_port);
    _ = i2s_helper_enable_tx(i2s_port);

    log.info("AudioSystem: Start ES8311", .{});
    es8311Start();
    es8311SetVolume(150);

    idf.time.sleepMs(10);

    log.info("AudioSystem: Start ES7210", .{});
    es7210Start();

    log.info("AudioSystem: Init AEC", .{});
    // "RM" = Reference first, Mic second (same as h2xx)
    // type=1 (AFE_TYPE_VC), mode=0 (AFE_MODE_LOW_COST)
    // filter_length=2 (smaller = less artifacts but weaker echo cancellation)
    g_aec_handle = aec_helper_create("RM", 2, 1, 0);
    if (g_aec_handle == null) {
        return error.AecInitFailed;
    }

    g_aec_frame_size = @intCast(aec_helper_get_chunksize(g_aec_handle.?));
    const total_ch: usize = @intCast(aec_helper_get_total_channels(g_aec_handle.?));
    log.info("AudioSystem: AEC frame={}, ch={}", .{ g_aec_frame_size, total_ch });

    // Allocate buffers in PSRAM
    const allocator = idf.heap.psram;

    g_raw_buffer_32 = allocator.alloc(i32, g_aec_frame_size * 2) catch {
        log.err("Failed to alloc raw_buffer", .{});
        return error.OutOfMemory;
    };
    errdefer if (g_raw_buffer_32) |b| allocator.free(b);

    g_aec_input = allocator.alloc(i16, g_aec_frame_size * total_ch) catch {
        log.err("Failed to alloc aec_input", .{});
        return error.OutOfMemory;
    };
    errdefer if (g_aec_input) |b| allocator.free(b);

    // AEC output needs 16-byte alignment
    g_aec_output = allocator.alignedAlloc(i16, .@"16", g_aec_frame_size) catch {
        log.err("Failed to alloc aec_output", .{});
        return error.OutOfMemory;
    };
    errdefer if (g_aec_output) |b| allocator.free(b);

    g_tx_buffer_32 = allocator.alloc(i32, g_aec_frame_size * 2) catch {
        log.err("Failed to alloc tx_buffer", .{});
        return error.OutOfMemory;
    };

    g_initialized = true;
    log.info("AudioSystem: Ready!", .{});
}

fn deinitAudioSystem() void {
    const allocator = idf.heap.psram;
    if (g_aec_handle) |h| {
        aec_helper_destroy(h);
        g_aec_handle = null;
    }
    if (g_raw_buffer_32) |b| allocator.free(b);
    if (g_aec_input) |b| allocator.free(b);
    if (g_aec_output) |b| allocator.free(b);
    if (g_tx_buffer_32) |b| allocator.free(b);
    g_raw_buffer_32 = null;
    g_aec_input = null;
    g_aec_output = null;
    g_tx_buffer_32 = null;
    _ = i2s_helper_deinit(i2s_port);
    i2c_helper_deinit();
    g_initialized = false;
}

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

    pub fn init() !Self {
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
// Speaker Driver (ES8311 DAC)
// ============================================================================

pub const SpeakerDriver = struct {
    const Self = @This();

    initialized: bool = false,

    pub fn init() !Self {
        return Self{ .initialized = true };
    }

    pub fn deinit(_: *Self) void {}

    pub fn write(_: *Self, buffer: []const i16) !usize {
        if (!g_initialized) return error.NotInitialized;

        const tx_buf = g_tx_buffer_32 orelse return error.NoBuffer;
        const frame_size = g_aec_frame_size;
        const mono_samples = @min(buffer.len, frame_size);

        // Convert mono i16 to stereo i32 (shift to upper 16 bits)
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

    pub fn setVolume(_: *Self, volume: u8) !void {
        es8311SetVolume(volume);
    }
};

// ============================================================================
// Microphone Driver with AEC (ES7210 ADC)
// ============================================================================

pub const MicDriver = struct {
    const Self = @This();

    initialized: bool = false,

    pub fn init() !Self {
        try initAudioSystem();
        return Self{ .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            deinitAudioSystem();
            self.initialized = false;
        }
    }

    pub fn read(_: *Self, buffer: []i16) !usize {
        if (!g_initialized) return error.NotInitialized;

        const aec_handle = g_aec_handle orelse return error.NoAec;
        const raw_buf = g_raw_buffer_32 orelse return error.NoBuffer;
        const aec_in = g_aec_input orelse return error.NoBuffer;
        const aec_out = g_aec_output orelse return error.NoBuffer;
        const frame_size = g_aec_frame_size;

        const to_read = frame_size * 2 * @sizeOf(i32);
        var bytes_read: usize = 0;
        const raw_bytes = std.mem.sliceAsBytes(raw_buf[0 .. frame_size * 2]);
        const ret = i2s_helper_read(i2s_port, raw_bytes.ptr, to_read, &bytes_read, 1000);

        if (ret != 0 or bytes_read == 0) {
            return 0;
        }

        const frames_read = bytes_read / @sizeOf(i32) / 2;

        // Extract MIC1 and REF - pack as "RM" (ref first, mic second)
        for (0..frames_read) |i| {
            const L = raw_buf[i * 2];
            const mic1: i16 = @truncate(L >> 16);
            const ref: i16 = @truncate(L & 0xFFFF);
            aec_in[i * 2 + 0] = ref; // Reference first
            aec_in[i * 2 + 1] = mic1; // Mic second
        }

        // Run AEC
        _ = aec_helper_process(aec_handle, aec_in.ptr, aec_out.ptr);

        const copy_len = @min(buffer.len, frames_read);
        @memcpy(buffer[0..copy_len], aec_out[0..copy_len]);

        return copy_len;
    }

    pub fn setGain(_: *Self, _: i8) !void {}
    pub fn start(_: *Self) !void {}
    pub fn stop(_: *Self) !void {}

    pub fn getFrameSize(_: *const Self) usize {
        return g_aec_frame_size;
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

    // TCA9554 register addresses
    const REG_OUTPUT: u8 = 0x01;
    const REG_CONFIG: u8 = 0x03;

    // Pin masks
    const RED_MASK: u8 = 1 << led_red_pin;
    const BLUE_MASK: u8 = 1 << led_blue_pin;
    const LED_MASK: u8 = RED_MASK | BLUE_MASK;

    initialized: bool = false,
    output_cache: u8 = 0xFF, // All high (LEDs off, active low)
    i2c_initialized_here: bool = false,

    pub fn init() !Self {
        var self = Self{};

        // Initialize I2C if not already done by audio system
        if (!g_initialized) {
            if (i2c_helper_init(i2c_sda, i2c_scl, i2c_freq_hz, 0) != 0) {
                return error.I2cInitFailed;
            }
            self.i2c_initialized_here = true;
        }

        // Configure LED pins as outputs (0 = output in TCA9554)
        var config = tca9554Read(REG_CONFIG);
        config &= ~LED_MASK; // Set LED pins as outputs
        tca9554Write(REG_CONFIG, config);

        // Turn off LEDs initially (high = off, active low)
        self.output_cache = tca9554Read(REG_OUTPUT);
        self.output_cache |= LED_MASK;
        tca9554Write(REG_OUTPUT, self.output_cache);

        self.initialized = true;
        log.info("LedDriver: TCA9554 @ 0x{x} initialized", .{tca9554_addr});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            // Turn off LEDs
            self.output_cache |= LED_MASK;
            tca9554Write(REG_OUTPUT, self.output_cache);

            if (self.i2c_initialized_here) {
                i2c_helper_deinit();
            }
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

        // Active low: clear bit = on, set bit = off
        if (red_on) {
            self.output_cache &= ~RED_MASK;
        } else {
            self.output_cache |= RED_MASK;
        }

        if (blue_on) {
            self.output_cache &= ~BLUE_MASK;
        } else {
            self.output_cache |= BLUE_MASK;
        }

        tca9554Write(REG_OUTPUT, self.output_cache);
    }

    pub fn getPixelCount(_: *Self) u32 {
        return 1;
    }

    pub fn refresh(_: *Self) void {
        // No-op: TCA9554 updates are synchronous
    }

    // Convenience methods
    pub fn setRed(self: *Self, on: bool) void {
        if (on) {
            self.output_cache &= ~RED_MASK;
        } else {
            self.output_cache |= RED_MASK;
        }
        tca9554Write(REG_OUTPUT, self.output_cache);
    }

    pub fn setBlue(self: *Self, on: bool) void {
        if (on) {
            self.output_cache &= ~BLUE_MASK;
        } else {
            self.output_cache |= BLUE_MASK;
        }
        tca9554Write(REG_OUTPUT, self.output_cache);
    }

    pub fn off(self: *Self) void {
        self.output_cache |= LED_MASK;
        tca9554Write(REG_OUTPUT, self.output_cache);
    }
};

/// RGB color (packed struct compatible with hal.Color)
pub const Color = packed struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    pub const black = Color{};
    pub const red = Color{ .r = 255 };
    pub const green = Color{ .g = 255 };
    pub const blue = Color{ .b = 255 };
    pub const white = Color{ .r = 255, .g = 255, .b = 255 };
};

// TCA9554 I2C helpers
fn tca9554Write(reg: u8, val: u8) void {
    const buf = [_]u8{ reg, val };
    _ = i2c_helper_write(tca9554_addr, &buf, 2, 100);
}

fn tca9554Read(reg: u8) u8 {
    var val: [1]u8 = undefined;
    _ = i2c_helper_write_read(tca9554_addr, &[_]u8{reg}, 1, &val, 1, 100);
    return val[0];
}

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
