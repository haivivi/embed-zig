//! Korvo-2 V3 Board Implementation
//!
//! Hardware:
//! - Boot button on GPIO0
//! - TCA9554 I2C GPIO expander with red/blue LEDs

const std = @import("std");
const idf = @import("esp");
const hal = @import("hal");
const drivers = @import("drivers");

const hw_params = idf.boards.korvo2_v3;

// ============================================================================
// Hardware Info
// ============================================================================

pub const Hardware = struct {
    pub const name = hw_params.name;
    pub const serial_port = hw_params.serial_port;
    pub const boot_button_gpio: idf.gpio.Pin = hw_params.boot_button_gpio;
    pub const has_led = true;
    pub const led_type = "tca9554";
    pub const led_count: u32 = 1;
    pub const i2c_sda: u8 = hw_params.i2c_sda;
    pub const i2c_scl: u8 = hw_params.i2c_scl;
    pub const i2c_freq_hz: u32 = hw_params.i2c_freq_hz;
    pub const tca9554_addr: u7 = hw_params.tca9554_addr;
};

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
        return idf.nowMs();
    }

    pub fn nowMs(_: *Self) ?i64 {
        return null;
    }
};

// ============================================================================
// Button Driver
// ============================================================================

pub const ButtonDriver = struct {
    const Self = @This();

    gpio: idf.gpio.Pin,
    initialized: bool = false,

    pub fn init() !Self {
        try idf.gpio.configInput(Hardware.boot_button_gpio, true);
        std.log.info("Korvo2 ButtonDriver: GPIO{} initialized", .{Hardware.boot_button_gpio});
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

const I2c = idf.sal.I2c;
const Tca9554 = drivers.Tca9554(*I2c);
const Pin = drivers.tca9554.Pin;
const RED_PIN = Pin.pin6;
const BLUE_PIN = Pin.pin7;

pub const LedDriver = struct {
    const Self = @This();

    i2c: I2c,
    gpio: Tca9554,
    initialized: bool = false,
    current_color: hal.Color = hal.Color.black,

    pub fn init() !Self {
        var self = Self{ .i2c = undefined, .gpio = undefined };

        self.i2c = try I2c.init(.{
            .sda = Hardware.i2c_sda,
            .scl = Hardware.i2c_scl,
            .freq_hz = Hardware.i2c_freq_hz,
        });
        errdefer self.i2c.deinit();

        self.gpio = Tca9554.init(&self.i2c, Hardware.tca9554_addr);
        try self.gpio.configureOutput(RED_PIN, .high);
        try self.gpio.configureOutput(BLUE_PIN, .high);

        self.initialized = true;
        std.log.info("Korvo2 LedDriver: TCA9554 @ 0x{x} initialized", .{Hardware.tca9554_addr});
        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.initialized) {
            self.gpio.write(RED_PIN, .high) catch {};
            self.gpio.write(BLUE_PIN, .high) catch {};
            self.i2c.deinit();
            self.initialized = false;
        }
    }

    pub fn setPixel(self: *Self, index: u32, color: hal.Color) void {
        if (index > 0) return;
        self.current_color = color;

        const brightness = @max(color.r, @max(color.g, color.b));
        const threshold: u8 = 30;

        var red_on = false;
        var blue_on = false;

        if (brightness >= threshold) {
            if (color.r > color.b + 50) {
                red_on = true;
            } else if (color.b > color.r + 50) {
                blue_on = true;
            } else {
                red_on = true;
                blue_on = true;
            }
        }

        self.gpio.write(RED_PIN, if (red_on) .low else .high) catch {};
        self.gpio.write(BLUE_PIN, if (blue_on) .low else .high) catch {};
    }

    pub fn getPixelCount(_: *Self) u32 {
        return 1;
    }

    pub fn refresh(_: *Self) void {}
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

// Platform primitives
pub const log = std.log.scoped(.app);

pub const time = struct {
    pub fn sleepMs(ms: u32) void {
        idf.sal.time.sleepMs(ms);
    }

    pub fn getTimeMs() u64 {
        return idf.nowMs();
    }
};

pub fn isRunning() bool {
    return true; // ESP: always running
}
