//! AEC Test - Zig version matching C implementation exactly
//!
//! Uses only lib/esp modules (I2C, I2S, GPIO, AEC helpers)
//! No trait/hal abstractions - direct ESP-IDF style
//!
//! Hardware: ESP32-S3-Korvo-2 V3 with ES7210 ADC + ES8311 DAC

const std = @import("std");

// ============================================================================
// C imports and extern declarations
// ============================================================================

const c = @cImport({
    @cInclude("esp_log.h");
    @cInclude("esp_heap_caps.h");
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("esp_idf_version.h");
    @cInclude("driver/gpio.h");
});

// I2C helper functions (from lib/esp/src/i2c/helper.c)
extern fn i2c_helper_init(sda: c_int, scl: c_int, freq_hz: u32, port: c_int) c_int;
extern fn i2c_helper_deinit() void;
extern fn i2c_helper_write(addr: u8, buf: [*]const u8, len: usize, timeout_ms: u32) c_int;
extern fn i2c_helper_write_read(addr: u8, write_buf: [*]const u8, write_len: usize, read_buf: [*]u8, read_len: usize, timeout_ms: u32) c_int;

// I2S helper functions (from lib/esp/src/i2s/helper.c)
extern fn i2s_helper_init_std_duplex(port: c_int, sample_rate: u32, bits_per_sample: c_int, bclk_pin: c_int, ws_pin: c_int, din_pin: c_int, dout_pin: c_int, mclk_pin: c_int) c_int;
extern fn i2s_helper_deinit(port: c_int) c_int;
extern fn i2s_helper_enable_rx(port: c_int) c_int;
extern fn i2s_helper_enable_tx(port: c_int) c_int;
extern fn i2s_helper_read(port: c_int, buffer: [*]u8, buffer_size: usize, bytes_read: *usize, timeout_ms: u32) c_int;
extern fn i2s_helper_write(port: c_int, buffer: [*]const u8, buffer_size: usize, bytes_written: *usize, timeout_ms: u32) c_int;

// AEC helper functions (from lib/esp/src/sr/aec_helper.c)
const AecHandle = opaque {};
extern fn aec_helper_create(input_format: [*:0]const u8, filter_length: c_int, aec_type: c_int, mode: c_int) ?*AecHandle;
extern fn aec_helper_process(handle: *AecHandle, indata: [*]const i16, outdata: [*]i16) c_int;
extern fn aec_helper_get_chunksize(handle: *AecHandle) c_int;
extern fn aec_helper_get_total_channels(handle: *AecHandle) c_int;
extern fn aec_helper_destroy(handle: *AecHandle) void;

// ============================================================================
// Hardware Configuration (Korvo2-V3) - Same as C version
// ============================================================================

const I2S_PORT = 0;
const I2S_MCLK_PIN = 16;
const I2S_BCLK_PIN = 9;
const I2S_WS_PIN = 45;
const I2S_DIN_PIN = 10;
const I2S_DOUT_PIN = 8;

const I2C_SDA_PIN = 17;
const I2C_SCL_PIN = 18;
const ES8311_ADDR: u8 = 0x18;
const ES7210_ADDR: u8 = 0x40;

const SAMPLE_RATE: u32 = 16000;
const BITS_PER_SAMPLE = 32;

const PA_ENABLE_GPIO = 48;

// AEC configuration
const AEC_INPUT_FORMAT = "MR";
const AEC_FILTER_LENGTH = 4;
const AFE_TYPE_VC = 1;
const AFE_MODE_LOW_COST = 0;

// Test configuration
const SINE_FREQ = 500;
const SINE_AMP: i16 = 8000;

// ============================================================================
// ES8311 Registers
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
const ES8311_SYS_13: u8 = 0x13;
const ES8311_SYS_14: u8 = 0x14;
const ES8311_ADC_15: u8 = 0x15;
const ES8311_ADC_16: u8 = 0x16;
const ES8311_ADC_17: u8 = 0x17;
const ES8311_ADC_1B: u8 = 0x1B;
const ES8311_ADC_1C: u8 = 0x1C;
const ES8311_DAC_32: u8 = 0x32;
const ES8311_DAC_37: u8 = 0x37;
const ES8311_GPIO_44: u8 = 0x44;
const ES8311_GP_45: u8 = 0x45;

// ============================================================================
// ES7210 Registers
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

// ============================================================================
// Logging
// ============================================================================

fn logInfo(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (msg.len < buf.len) {
        buf[msg.len] = 0;
    }
    c.esp_log_write(c.ESP_LOG_INFO, "AEC_ZIG", "%s\n", @as([*:0]const u8, @ptrCast(&buf)));
}

fn logWarn(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (msg.len < buf.len) {
        buf[msg.len] = 0;
    }
    c.esp_log_write(c.ESP_LOG_WARN, "AEC_ZIG", "%s\n", @as([*:0]const u8, @ptrCast(&buf)));
}

fn logError(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    if (msg.len < buf.len) {
        buf[msg.len] = 0;
    }
    c.esp_log_write(c.ESP_LOG_ERROR, "AEC_ZIG", "%s\n", @as([*:0]const u8, @ptrCast(&buf)));
}

// ============================================================================
// I2C Helpers
// ============================================================================

fn es8311Write(reg: u8, val: u8) void {
    const buf = [_]u8{ reg, val };
    _ = i2c_helper_write(ES8311_ADDR, &buf, 2, 100);
}

fn es8311Read(reg: u8) u8 {
    var val: [1]u8 = undefined;
    _ = i2c_helper_write_read(ES8311_ADDR, &[_]u8{reg}, 1, &val, 1, 100);
    return val[0];
}

fn es7210Write(reg: u8, val: u8) void {
    const buf = [_]u8{ reg, val };
    _ = i2c_helper_write(ES7210_ADDR, &buf, 2, 100);
}

fn es7210Read(reg: u8) u8 {
    var val: [1]u8 = undefined;
    _ = i2c_helper_write_read(ES7210_ADDR, &[_]u8{reg}, 1, &val, 1, 100);
    return val[0];
}

fn es7210Update(reg: u8, mask: u8, val: u8) void {
    var regv = es7210Read(reg);
    regv = (regv & ~mask) | (val & mask);
    es7210Write(reg, regv);
}

// ============================================================================
// ES8311 Init (from C version es8311_init)
// ============================================================================

fn es8311Init() void {
    logInfo("ES8311 init...", .{});

    // Enhance I2C noise immunity
    es8311Write(ES8311_GPIO_44, 0x08);
    es8311Write(ES8311_GPIO_44, 0x08);

    // Initial register setup
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

    // Slave mode
    var regv = es8311Read(ES8311_RESET);
    regv &= 0xBF;
    es8311Write(ES8311_RESET, regv);

    // MCLK source
    regv = 0x3F & 0x7F;
    es8311Write(ES8311_CLK_MGR_01, regv);

    // SCLK
    regv = es8311Read(ES8311_CLK_MGR_06);
    regv &= ~@as(u8, 0x20);
    es8311Write(ES8311_CLK_MGR_06, regv);

    // Additional init
    es8311Write(ES8311_SYS_13, 0x10);
    es8311Write(ES8311_ADC_1B, 0x0A);
    es8311Write(ES8311_ADC_1C, 0x6A);

    // DAC reference for AEC
    es8311Write(ES8311_GPIO_44, 0x58);

    logInfo("ES8311 init done", .{});
}

fn es8311Start() void {
    var regv: u8 = 0x80;
    es8311Write(ES8311_RESET, regv);

    regv = 0x3F & 0x7F;
    es8311Write(ES8311_CLK_MGR_01, regv);

    // Configure SDP
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

    // digital_mic = false
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
// ES7210 Init (from C version es7210_init)
// ============================================================================

fn es7210Init() void {
    logInfo("ES7210 init...", .{});

    // Reset
    es7210Write(ES7210_RESET, 0xFF);
    c.vTaskDelay(10 / c.portTICK_PERIOD_MS);
    es7210Write(ES7210_RESET, 0x41);

    // Clock setup
    es7210Write(ES7210_CLK_OFF, 0x3F);
    es7210Write(ES7210_TIME_CTL0, 0x30);
    es7210Write(ES7210_TIME_CTL1, 0x30);

    // HPF setup
    es7210Write(ES7210_ADC12_HPF2, 0x2A);
    es7210Write(ES7210_ADC12_HPF1, 0x0A);
    es7210Write(ES7210_ADC34_HPF2, 0x0A);
    es7210Write(ES7210_ADC34_HPF1, 0x2A);

    // Unmute all ADCs
    es7210Write(ES7210_ADC12_MUTE, 0x00);
    es7210Write(ES7210_ADC34_MUTE, 0x00);

    // Slave mode
    es7210Update(ES7210_MODE_CFG, 0x01, 0x00);

    // Analog power and bias
    es7210Write(ES7210_ANALOG, 0x43);
    es7210Write(ES7210_MIC12_BIAS, 0x70);
    es7210Write(ES7210_MIC34_BIAS, 0x70);
    es7210Write(ES7210_OSR, 0x20);

    // Clock divider with DLL
    es7210Write(ES7210_MAIN_CLK, 0xC1);

    // LRCK divider for 16kHz
    es7210Write(ES7210_LRCK_DIV_H, 0x02);
    es7210Write(ES7210_LRCK_DIV_L, 0x00);

    // Disable all MIC gain first
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        es7210Update(ES7210_MIC1_GAIN + i, 0x10, 0x00);
    }

    // Power down all MICs
    es7210Write(ES7210_MIC12_PWR, 0xFF);
    es7210Write(ES7210_MIC34_PWR, 0xFF);

    // Enable MIC1 (30dB gain)
    logInfo("Enable ES7210_INPUT_MIC1", .{});
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC1_GAIN, 0x0F, 0x0A);

    // Enable MIC2 (30dB gain)
    logInfo("Enable ES7210_INPUT_MIC2", .{});
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC2_GAIN, 0x0F, 0x0A);

    // Enable MIC3/REF (30dB gain)
    logInfo("Enable ES7210_INPUT_MIC3", .{});
    es7210Update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210Write(ES7210_MIC34_PWR, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC3_GAIN, 0x0F, 0x0A);

    // Enable TDM mode
    es7210Write(ES7210_SDP_IF2, 0x02);
    logWarn("ES7210 TDM enabled (0x02), but I2S uses STD mode", .{});

    // Set I2S format AND force 16-bit width
    var adc_iface = es7210Read(ES7210_SDP_IF1);
    logInfo("ES7210 SDP_IF1 before = 0x{X:0>2}", .{adc_iface});
    adc_iface &= 0x1C;
    adc_iface |= 0x00; // I2S Philips format
    adc_iface |= 0x60; // 16-bit word length
    es7210Write(ES7210_SDP_IF1, adc_iface);
    logInfo("ES7210 SDP_IF1 set to 0x{X:0>2} (16-bit, I2S)", .{adc_iface});

    // Final analog
    es7210Write(ES7210_ANALOG, 0x43);

    // Start sequence
    es7210Write(ES7210_RESET, 0x71);
    es7210Write(ES7210_RESET, 0x41);

    logInfo("ES7210 init done", .{});
}

fn es7210Start() void {
    const clock_reg_value: u8 = 0x20;

    es7210Write(ES7210_CLK_OFF, clock_reg_value);
    es7210Write(ES7210_POWER_DOWN, 0x00);
    es7210Write(ES7210_ANALOG, 0x43);
    es7210Write(ES7210_MIC1_PWR, 0x08);
    es7210Write(ES7210_MIC2_PWR, 0x08);
    es7210Write(ES7210_MIC3_PWR, 0x08);
    es7210Write(ES7210_MIC4_PWR, 0x08);

    // Re-call mic_select logic
    var i: u8 = 0;
    while (i < 4) : (i += 1) {
        es7210Update(ES7210_MIC1_GAIN + i, 0x10, 0x00);
    }
    es7210Write(ES7210_MIC12_PWR, 0xFF);
    es7210Write(ES7210_MIC34_PWR, 0xFF);

    // MIC1 (30dB)
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC1_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC1_GAIN, 0x0F, 0x0A);

    // MIC2 (30dB)
    es7210Update(ES7210_CLK_OFF, 0x0B, 0x00);
    es7210Write(ES7210_MIC12_PWR, 0x00);
    es7210Update(ES7210_MIC2_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC2_GAIN, 0x0F, 0x0A);

    // MIC3/REF (30dB)
    es7210Update(ES7210_CLK_OFF, 0x15, 0x00);
    es7210Write(ES7210_MIC34_PWR, 0x00);
    es7210Update(ES7210_MIC3_GAIN, 0x10, 0x10);
    es7210Update(ES7210_MIC3_GAIN, 0x0F, 0x0A);

    // Enable TDM mode
    es7210Write(ES7210_SDP_IF2, 0x02);

    logInfo("ES7210 started (MIC1+MIC2+MIC3, TDM, gain=30dB)", .{});
}

// ============================================================================
// PA Init
// ============================================================================

fn paInit() void {
    _ = c.gpio_reset_pin(PA_ENABLE_GPIO);
    _ = c.gpio_set_direction(PA_ENABLE_GPIO, c.GPIO_MODE_OUTPUT);
    _ = c.gpio_set_level(PA_ENABLE_GPIO, 1);
    logInfo("PA enabled (GPIO {})", .{PA_ENABLE_GPIO});
}

// ============================================================================
// Audio Task
// ============================================================================

var g_aec_handle: ?*AecHandle = null;
var g_aec_frame_size: usize = 0;

fn audioTask(_: ?*anyopaque) callconv(.c) void {
    logInfo("Audio task started: AEC + SINE TEST (freq={}Hz)", .{SINE_FREQ});

    const aec_handle = g_aec_handle orelse {
        logError("AEC handle is null", .{});
        c.vTaskDelete(null);
        return;
    };

    const frame_size = g_aec_frame_size;
    const total_ch: usize = @intCast(aec_helper_get_total_channels(aec_handle));

    // Allocate buffers in PSRAM using optional pointers for null checking
    const raw_buffer_32: ?[*]i32 = @ptrCast(@alignCast(c.heap_caps_malloc(frame_size * 2 * @sizeOf(i32), c.MALLOC_CAP_SPIRAM)));
    const aec_input: ?[*]i16 = @ptrCast(@alignCast(c.heap_caps_malloc(frame_size * total_ch * @sizeOf(i16), c.MALLOC_CAP_SPIRAM)));
    const aec_output: ?[*]i16 = @ptrCast(@alignCast(c.heap_caps_aligned_alloc(16, frame_size * @sizeOf(i16), c.MALLOC_CAP_SPIRAM)));
    const tx_buffer_32: ?[*]i32 = @ptrCast(@alignCast(c.heap_caps_malloc(frame_size * 2 * @sizeOf(i32), c.MALLOC_CAP_SPIRAM)));

    if (raw_buffer_32 == null or aec_input == null or aec_output == null or tx_buffer_32 == null) {
        logError("Buffer allocation failed", .{});
        c.vTaskDelete(null);
        return;
    }

    // Unwrap optional pointers
    const raw_buf = raw_buffer_32.?;
    const aec_in = aec_input.?;
    const aec_out = aec_output.?;
    const tx_buf = tx_buffer_32.?;

    // Pre-calculate sine wave table
    const sine_period: usize = SAMPLE_RATE / SINE_FREQ;
    const sine_table: ?[*]i16 = @ptrCast(@alignCast(c.heap_caps_malloc(sine_period * @sizeOf(i16), c.MALLOC_CAP_DEFAULT)));
    if (sine_table == null) {
        logError("Sine table allocation failed", .{});
        c.vTaskDelete(null);
        return;
    }
    const sine_tbl = sine_table.?;

    var si: usize = 0;
    while (si < sine_period) : (si += 1) {
        const angle: f32 = 2.0 * std.math.pi * @as(f32, @floatFromInt(si)) / @as(f32, @floatFromInt(sine_period));
        sine_tbl[si] = @intFromFloat(@as(f32, @floatFromInt(SINE_AMP)) * @sin(angle));
    }
    logInfo("Sine table: period={} samples", .{sine_period});

    var frame_count: u32 = 0;
    var sine_idx: usize = 0;

    while (true) {
        // Read stereo 32-bit from I2S
        const to_read = frame_size * 2 * @sizeOf(i32);
        var bytes_read: usize = 0;
        const ret = i2s_helper_read(I2S_PORT, @ptrCast(raw_buf), to_read, &bytes_read, 1000);

        if (ret != 0 or bytes_read == 0) {
            if (ret == 0x107) { // ESP_ERR_TIMEOUT
                logWarn("I2S read timeout", .{});
            }
            continue;
        }

        // Extract MIC1 and REF from TDM data
        var mic_energy: i64 = 0;
        var ref_energy: i64 = 0;

        var i: usize = 0;
        while (i < frame_size) : (i += 1) {
            const L = raw_buf[i * 2 + 0];
            const mic1: i16 = @truncate(L >> 16); // MIC1 = L_HI
            const ref: i16 = @truncate(L & 0xFFFF); // REF = L_LO (MIC3)

            // Pack into "MR" format
            aec_in[i * 2 + 0] = mic1;
            aec_in[i * 2 + 1] = ref;

            mic_energy += @as(i64, mic1) * @as(i64, mic1);
            ref_energy += @as(i64, ref) * @as(i64, ref);
        }

        // Run AEC
        _ = aec_helper_process(aec_handle, aec_in, aec_out);

        // Calculate output energy
        var out_energy: i64 = 0;
        i = 0;
        while (i < frame_size) : (i += 1) {
            out_energy += @as(i64, aec_out[i]) * @as(i64, aec_out[i]);
        }

        // Generate output: Sine + AEC
        i = 0;
        while (i < frame_size) : (i += 1) {
            const sine_sample = sine_tbl[sine_idx];
            sine_idx = (sine_idx + 1) % sine_period;

            // Mix sine wave with AEC output (boost mic by 4x)
            var mixed: i32 = @divTrunc(@as(i32, sine_sample), 2) + @as(i32, aec_out[i]) * 4;
            if (mixed > 32767) mixed = 32767;
            if (mixed < -32768) mixed = -32768;

            const sample32: i32 = @as(i32, @as(i16, @truncate(mixed))) << 16;
            tx_buf[i * 2 + 0] = sample32;
            tx_buf[i * 2 + 1] = sample32;
        }

        // Log every 50 frames
        if (frame_count % 50 == 0) {
            const mic_rms: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(mic_energy)) / @as(f64, @floatFromInt(frame_size))));
            const ref_rms: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(ref_energy)) / @as(f64, @floatFromInt(frame_size))));
            const out_rms: i32 = @intFromFloat(@sqrt(@as(f64, @floatFromInt(out_energy)) / @as(f64, @floatFromInt(frame_size))));
            logInfo("AEC: MIC={} REF={} OUT={} (sine={}Hz)", .{ mic_rms, ref_rms, out_rms, SINE_FREQ });
        }

        var bytes_written: usize = 0;
        _ = i2s_helper_write(I2S_PORT, @ptrCast(tx_buf), frame_size * 2 * @sizeOf(i32), &bytes_written, c.portMAX_DELAY);
        frame_count += 1;
    }
}

// ============================================================================
// App Main
// ============================================================================

export fn app_main() void {
    logInfo("=== AEC Test (Zig) - Matching C version ===", .{});

    // Initialize I2C
    if (i2c_helper_init(I2C_SDA_PIN, I2C_SCL_PIN, 400000, 0) != 0) {
        logError("I2C init failed", .{});
        return;
    }

    // Initialize codecs
    es8311Init();
    es7210Init();

    // Initialize I2S (STD mode, stereo 32-bit)
    logInfo("I2S STD init: port={}, rate={}, stereo 32-bit", .{ I2S_PORT, SAMPLE_RATE });
    if (i2s_helper_init_std_duplex(I2S_PORT, SAMPLE_RATE, BITS_PER_SAMPLE, I2S_BCLK_PIN, I2S_WS_PIN, I2S_DIN_PIN, I2S_DOUT_PIN, I2S_MCLK_PIN) != 0) {
        logError("I2S init failed", .{});
        return;
    }
    _ = i2s_helper_enable_rx(I2S_PORT);
    _ = i2s_helper_enable_tx(I2S_PORT);
    logInfo("I2S STD stereo 32-bit init done", .{});

    // Start ES8311 and set volume
    es8311Start();
    es8311SetVolume(150);

    // Enable PA
    paInit();

    // Small delay for clocks to stabilize
    c.vTaskDelay(10 / c.portTICK_PERIOD_MS);

    // Start ES7210 ADC
    es7210Start();

    // Debug: Read ES7210 registers
    logWarn("=== ES7210 Register Dump ===", .{});
    logWarn("CLK_OFF (0x01): 0x{X:0>2}", .{es7210Read(ES7210_CLK_OFF)});
    logWarn("SDP_IF1 (0x11): 0x{X:0>2}", .{es7210Read(ES7210_SDP_IF1)});
    const sdp_if2 = es7210Read(ES7210_SDP_IF2);
    logWarn("SDP_IF2 (0x12): 0x{X:0>2} (TDM={s})", .{ sdp_if2, if ((sdp_if2 & 0x02) != 0) "ON" else "OFF" });
    logWarn("=== End Register Dump ===", .{});

    // Initialize AEC
    logInfo("AEC init: format={s}, filter={}", .{ AEC_INPUT_FORMAT, AEC_FILTER_LENGTH });
    g_aec_handle = aec_helper_create(AEC_INPUT_FORMAT, AEC_FILTER_LENGTH, AFE_TYPE_VC, AFE_MODE_LOW_COST);
    if (g_aec_handle == null) {
        logError("AEC create failed", .{});
        return;
    }

    g_aec_frame_size = @intCast(aec_helper_get_chunksize(g_aec_handle.?));
    const total_ch = aec_helper_get_total_channels(g_aec_handle.?);
    logInfo("AEC: frame={}, total_ch={}", .{ g_aec_frame_size, total_ch });

    logInfo("All init done, starting audio...", .{});

    // Create audio task
    var task_handle: c.TaskHandle_t = null;
    _ = c.xTaskCreate(
        audioTask,
        "audio",
        8192,
        null,
        5,
        &task_handle,
    );
}
