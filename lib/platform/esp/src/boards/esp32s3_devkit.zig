//! Hardware Definition & Drivers: ESP32-S3 DevKitC
//!
//! This file defines hardware configuration and provides pre-configured drivers
//! for the ESP32-S3 DevKitC board.
//!
//! Usage:
//!   const board = @import("esp").boards.esp32s3_devkit;
//!   pub const LedDriver = board.LedDriver;
//!   pub const ButtonDriver = board.BootButtonDriver;
//!   pub const WifiDriver = board.WifiDriver;

const std = @import("std");
const idf = @import("idf");
const impl = @import("impl");
const hal = @import("hal");

// ============================================================================
// Thread-safe Queue (for HAL event queue)
// ============================================================================

/// FreeRTOS-based thread-safe queue for multi-task event handling
pub const Queue = idf.Queue;

// ============================================================================
// Board Identification
// ============================================================================

/// Board name
pub const name = "ESP32-S3-DevKitC";

/// Serial port for flashing
pub const serial_port = "/dev/cu.usbmodem1301";

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
// GPIO Definitions
// ============================================================================

/// BOOT button GPIO
pub const boot_button_gpio: u8 = 0;

// ============================================================================
// LED Strip Configuration (Built-in WS2812 RGB LED)
// ============================================================================

/// LED Strip GPIO (Built-in WS2812)
pub const led_strip_gpio: c_int = 48;

/// Number of LEDs
pub const led_strip_count: u32 = 1;

/// Default brightness (0-255)
pub const led_strip_default_brightness: u8 = 128;

// ============================================================================
// Platform Helpers
// ============================================================================

pub const log = std.log.scoped(.board);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }
    pub fn nowMs() u64 {
        return idf.time.nowMs();
    }
};

pub fn isRunning() bool {
    return true;
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
// LED Driver (WS2812 RGB LED)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();
    pub const Color = hal.Color;

    strip: idf.LedStrip,
    initialized: bool = false,

    pub fn init() !Self {
        const strip = try idf.LedStrip.init(
            .{ .strip_gpio_num = led_strip_gpio, .max_leds = led_strip_count },
            .{ .resolution_hz = 10_000_000 },
        );
        log.info("LedDriver: WS2812 @ GPIO{} initialized", .{led_strip_gpio});
        return Self{ .strip = strip, .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.strip.clear() catch {};
            self.strip.deinit();
            self.initialized = false;
        }
    }

    pub fn setPixel(self: *Self, index: u32, color: Color) void {
        if (index >= led_strip_count or !self.initialized) return;
        self.strip.setPixel(index, color.r, color.g, color.b) catch {};
    }

    pub fn getPixelCount(_: *Self) u32 {
        return led_strip_count;
    }

    pub fn refresh(self: *Self) void {
        if (self.initialized) {
            self.strip.refresh() catch {};
        }
    }

    pub fn clear(self: *Self) void {
        if (self.initialized) {
            self.strip.clear() catch {};
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

// WiFi Driver is provided by impl.wifi.WifiDriver (line 33)
