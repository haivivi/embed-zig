//! LED Implementation for ESP32
//!
//! Implements hal.led Driver interface using idf.pwm (LEDC).
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const led_spec = struct {
//!       pub const Driver = impl.LedDriver;
//!       pub const meta = .{ .id = "led.main" };
//!   };
//!   const Led = hal.led.from(led_spec);

const idf = @import("idf");

/// LED Driver that implements hal.led.Driver interface
/// Uses LEDC (PWM) for brightness control
pub const LedDriver = struct {
    const Self = @This();

    pwm: idf.Pwm,

    /// Initialize LED driver on GPIO pin
    pub fn init(gpio: u8) !Self {
        const pwm = try idf.Pwm.init(.{
            .gpio = gpio,
            .freq_hz = 5000,
            .resolution_bits = 10,
        });
        return .{ .pwm = pwm };
    }

    /// Deinitialize LED driver
    pub fn deinit(self: *Self) void {
        self.pwm.deinit();
    }

    /// Set duty cycle 0-65535 (required by hal.led)
    pub fn setDuty(self: *Self, duty: u16) void {
        self.pwm.setDuty(duty);
    }

    /// Get current duty cycle (required by hal.led)
    pub fn getDuty(self: *const Self) u16 {
        return self.pwm.getDuty();
    }

    /// Fade to target duty (optional for hal.led)
    pub fn fade(self: *Self, target: u16, duration_ms: u32) void {
        self.pwm.fade(target, duration_ms);
    }
};
