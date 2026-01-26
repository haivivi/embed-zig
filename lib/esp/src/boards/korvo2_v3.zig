//! Hardware Definition: ESP32-S3-Korvo-2 V3
//!
//! This file defines the hardware configuration for the ESP32-S3-Korvo-2 V3 board.
//! It only contains pin definitions, ADC channels, voltage ranges, etc.
//! No HAL implementation - that's done by each application.
//!
//! Usage:
//!   const hw = @import("esp").boards.korvo2_v3;
//!   const channel = hw.adc_channel;
//!   const ranges = hw.button_voltage_ranges;

/// Board identification
pub const name = "ESP32-S3-Korvo-2-V3";

/// Serial port for flashing
pub const serial_port = "/dev/cu.usbserial-120";

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
/// Button  | Raw Value | Range
/// --------|-----------|------------
/// VOL+    | 410       | 250-600
/// VOL-    | 922       | 750-1100
/// SET     | 1275      | 1110-1500
/// PLAY    | 1928      | 1510-2100
/// MUTE    | 2312      | 2110-2550
/// REC     | 2852      | 2650-3100
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
pub const boot_button_gpio = 0;

/// I2S port for microphone
pub const mic_i2s_port = 0;

/// I2S port for speaker
pub const speaker_i2s_port = 1;

// ============================================================================
// I2C Configuration (for TCA9554 GPIO expander)
// ============================================================================

/// I2C SDA GPIO
pub const i2c_sda = 17;

/// I2C SCL GPIO
pub const i2c_scl = 18;

/// I2C frequency (Hz)
pub const i2c_freq_hz = 400_000;

/// TCA9554 I2C address
pub const tca9554_addr: u7 = 0x20;

// ============================================================================
// LED Configuration (via TCA9554 GPIO expander)
// ============================================================================

/// LED type: TCA9554 (not WS2812)
pub const led_type = .tca9554;

/// Red LED pin on TCA9554
pub const led_red_pin = 6; // TCA9554_GPIO_NUM_6

/// Blue LED pin on TCA9554
pub const led_blue_pin = 7; // TCA9554_GPIO_NUM_7

/// Number of LEDs (logical - for HAL compatibility)
pub const led_strip_count = 1;

/// Default brightness (0-255, but only on/off supported)
pub const led_strip_default_brightness = 128;

/// LED capabilities (for HAL)
pub const LedCapabilities = struct {
    /// Full RGB color support
    pub const rgb = false;
    /// Brightness control
    pub const brightness = false;
    /// Only red/blue/off
    pub const colors_available = .{ .red, .blue, .off };
};

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "buttonIndexFromAdc" {
    // Test button detection
    try std.testing.expectEqual(@as(u8, 0), buttonIndexFromAdc(410).?); // VOL+
    try std.testing.expectEqual(@as(u8, 1), buttonIndexFromAdc(922).?); // VOL-
    try std.testing.expectEqual(@as(u8, 2), buttonIndexFromAdc(1275).?); // SET
    try std.testing.expectEqual(@as(u8, 4), buttonIndexFromAdc(2312).?); // MUTE
    try std.testing.expectEqual(@as(u8, 5), buttonIndexFromAdc(2852).?); // REC

    // Test gap values
    try std.testing.expect(buttonIndexFromAdc(650) == null); // Between VOL+ and VOL-
    try std.testing.expect(buttonIndexFromAdc(200) == null); // Below VOL+
}

test "isIdle" {
    try std.testing.expect(isIdle(4095)); // Max value
    try std.testing.expect(isIdle(3500)); // Within tolerance
    try std.testing.expect(!isIdle(2000)); // Button pressed
    try std.testing.expect(!isIdle(500)); // Button pressed
}
