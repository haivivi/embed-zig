//! ESP32-S3 DevKit Board Implementation
//!
//! Hardware:
//! - WS2812 RGB LED

const std = @import("std");
const idf = @import("esp");
const hal = @import("hal");

// Export SAL for app.zig
pub const sal = idf.sal;

// Hardware parameters from lib/esp/boards
const hw_params = idf.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
    pub const led_type = "ws2812";
    pub const led_count: u32 = 1;
    pub const led_gpio: c_int = hw_params.led_strip_gpio;
};

// ============================================================================
// RTC Driver (required by hal.Board)
// ============================================================================

pub const RtcDriver = struct {
    const Self = @This();

    pub fn init() !Self {
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    pub fn uptime(_: *Self) u64 {
        return idf.nowMs();
    }

    pub fn read(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// LED Driver (implements HAL LedStrip.Driver interface)
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();

    strip: idf.LedStrip,
    initialized: bool = false,
    current_color: hal.Color = hal.Color.black,

    pub fn init() !Self {
        const strip = try idf.LedStrip.init(
            .{
                .strip_gpio_num = Hardware.led_gpio,
                .max_leds = Hardware.led_count,
            },
            .{ .resolution_hz = 10_000_000 },
        );

        std.log.info("DevKit LedDriver: WS2812 @ GPIO{} initialized", .{Hardware.led_gpio});

        return .{
            .strip = strip,
            .initialized = true,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.strip.clear() catch {};
            self.strip.deinit();
            self.initialized = false;
        }
    }

    pub fn setPixel(self: *Self, index: u32, color: hal.Color) void {
        if (index >= Hardware.led_count) return;
        self.current_color = color;
        self.strip.setPixel(index, color.r, color.g, color.b) catch {};
    }

    pub fn getPixelCount(_: *Self) u32 {
        return Hardware.led_count;
    }

    pub fn refresh(self: *Self) void {
        self.strip.refresh() catch {};
    }
};

// ============================================================================
// HAL Specs
// ============================================================================

pub const rtc_spec = struct {
    pub const Driver = RtcDriver;
    pub const meta = hal.Meta{ .id = "rtc" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = hal.Meta{ .id = "led.main" };
};
