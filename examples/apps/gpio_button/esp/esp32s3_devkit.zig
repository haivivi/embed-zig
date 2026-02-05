//! ESP32-S3 DevKit Board Implementation
//!
//! Hardware:
//! - Boot button on GPIO0
//! - WS2812 RGB LED on GPIO48

const std = @import("std");
const esp = @import("esp");
const hal = @import("hal");

const idf = esp.idf;
const board = esp.boards.esp32s3_devkit;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = board.name;
    pub const serial_port = board.serial_port;
    pub const boot_button_gpio: idf.gpio.Pin = board.boot_button_gpio;
    pub const has_led = true;
    pub const led_type = "ws2812";
    pub const led_count: u32 = 1;
    pub const led_gpio: c_int = board.led_strip_gpio;
};

// ============================================================================
// Drivers (re-export from central board)
// ============================================================================

pub const RtcDriver = board.RtcDriver;

// ============================================================================
// Button Driver
// ============================================================================

pub const ButtonDriver = struct {
    const Self = @This();

    gpio: idf.gpio.Pin,
    initialized: bool = false,

    pub fn init() !Self {
        try idf.gpio.configInput(Hardware.boot_button_gpio, true);
        std.log.info("DevKit ButtonDriver: GPIO{} initialized", .{Hardware.boot_button_gpio});
        return .{ .gpio = Hardware.boot_button_gpio, .initialized = true };
    }

    pub fn deinit(self: *Self) void {
        self.initialized = false;
    }

    pub fn isPressed(self: *const Self) bool {
        return idf.gpio.getLevel(self.gpio) == 0;
    }
};

// ============================================================================
// LED Driver
// ============================================================================

pub const LedDriver = struct {
    const Self = @This();

    strip: idf.LedStrip,
    initialized: bool = false,
    current_color: hal.Color = hal.Color.black,

    pub fn init() !Self {
        const strip = try idf.LedStrip.init(
            .{ .strip_gpio_num = Hardware.led_gpio, .max_leds = Hardware.led_count },
            .{ .resolution_hz = 10_000_000 },
        );
        std.log.info("DevKit LedDriver: WS2812 @ GPIO{} initialized", .{Hardware.led_gpio});
        return .{ .strip = strip, .initialized = true };
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
    pub const meta = .{ .id = "rtc" };
};

pub const button_spec = struct {
    pub const Driver = ButtonDriver;
    pub const meta = .{ .id = "button.boot" };
};

pub const led_spec = struct {
    pub const Driver = LedDriver;
    pub const meta = .{ .id = "led.main" };
};

// Platform primitives (re-export from central board)
pub const log = std.log.scoped(.app);
pub const time = board.time;

pub fn isRunning() bool {
    return board.isRunning();
}
