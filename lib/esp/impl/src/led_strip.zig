//! LED Strip Implementation for ESP32
//!
//! Implements hal.led_strip Driver interface using idf.led_strip.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const led_spec = struct {
//!       pub const Driver = impl.LedStripDriver;
//!       pub const meta = .{ .id = "led.main" };
//!       pub const num_leds = 12;
//!   };
//!   const LedStrip = hal.led_strip.from(led_spec);

const idf = @import("idf");
const hal = @import("hal");

/// LED Strip Driver that implements hal.led_strip.Driver interface
pub const LedStripDriver = struct {
    const Self = @This();

    strip: idf.LedStrip,
    num_leds: u16,

    /// Initialize LED strip driver
    pub fn init(gpio: u8, num_leds: u16) !Self {
        const strip = try idf.LedStrip.init(.{
            .strip_gpio_num = @intCast(gpio),
            .max_leds = num_leds,
        }, .{
            .resolution_hz = 10_000_000, // Default RMT resolution
        });
        return .{ .strip = strip, .num_leds = num_leds };
    }

    /// Deinitialize LED strip driver
    pub fn deinit(self: *Self) void {
        self.strip.deinit();
    }

    /// Set single LED color (required by hal.led_strip)
    pub fn setPixel(self: *Self, index: u16, color: hal.Color) void {
        if (index < self.num_leds) {
            self.strip.setPixel(@intCast(index), color.r, color.g, color.b) catch {};
        }
    }

    /// Set all LEDs to same color (required by hal.led_strip)
    pub fn fill(self: *Self, color: hal.Color) void {
        var i: u32 = 0;
        while (i < self.num_leds) : (i += 1) {
            self.strip.setPixel(i, color.r, color.g, color.b) catch {};
        }
    }

    /// Refresh/update the LED strip (required by hal.led_strip)
    pub fn refresh(self: *Self) void {
        self.strip.refresh() catch {};
    }

    /// Clear all LEDs (required by hal.led_strip)
    pub fn clear(self: *Self) void {
        self.strip.clear() catch {};
    }

    /// Get number of LEDs (required by hal.led_strip)
    pub fn len(self: *const Self) u16 {
        return self.num_leds;
    }
};
