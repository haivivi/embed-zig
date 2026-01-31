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
const hal = @import("hal");

// ============================================================================
// Board Identification
// ============================================================================

/// Board name
pub const name = "ESP32-S3-DevKitC";

/// Serial port for flashing
pub const serial_port = "/dev/cu.usbmodem1301";

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
    pub fn getTimeMs() u64 {
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
