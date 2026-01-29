//! Button Implementation for ESP32
//!
//! Implements hal.button Driver interface using idf.gpio.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const hal = @import("hal");
//!
//!   const btn_spec = struct {
//!       pub const Driver = impl.ButtonDriver;
//!       pub const meta = .{ .id = "btn.power" };
//!   };
//!   const Button = hal.button.from(btn_spec);

const idf = @import("idf");

/// Button Driver that implements hal.button.Driver interface
/// Uses GPIO for button state reading
pub const ButtonDriver = struct {
    const Self = @This();

    gpio: u8,
    active_low: bool,

    /// Initialize button driver on GPIO pin
    /// active_low: true if button pulls GPIO low when pressed
    pub fn init(gpio: u8, active_low: bool) !Self {
        try idf.gpio.configInput(gpio, active_low); // Enable pull-up if active low
        return .{
            .gpio = gpio,
            .active_low = active_low,
        };
    }

    /// Check if button is pressed (required by hal.button)
    pub fn isPressed(self: *Self) bool {
        const level = idf.gpio.getLevel(self.gpio);
        return if (self.active_low) level == 0 else level == 1;
    }
};

/// Button configuration helper
pub const ButtonConfig = struct {
    gpio: u8,
    active_low: bool = true,
};
