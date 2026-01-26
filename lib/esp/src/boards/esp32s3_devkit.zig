//! Hardware Definition: ESP32-S3 DevKitC
//!
//! This file defines the hardware configuration for the ESP32-S3 DevKitC board.
//! It only contains pin definitions, etc.
//! No HAL implementation - that's done by each application.
//!
//! Usage:
//!   const hw = @import("esp").boards.esp32s3_devkit;

/// Board identification
pub const name = "ESP32-S3-DevKitC";

/// Serial port for flashing
pub const serial_port = "/dev/cu.usbmodem1301";

// ============================================================================
// GPIO Definitions
// ============================================================================

/// BOOT button GPIO
pub const boot_button_gpio = 0;

// ============================================================================
// LED Strip Configuration (Built-in RGB LED)
// ============================================================================

/// LED Strip GPIO (Built-in WS2812)
pub const led_strip_gpio = 48;

/// Number of LEDs
pub const led_strip_count = 1;

/// Default brightness (0-255)
pub const led_strip_default_brightness = 128;
