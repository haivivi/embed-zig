//! Button Implementation for BK7258
//!
//! Implements hal.button Driver interface using armino GPIO.

const armino = @import("../../armino/src/armino.zig");

/// Button Driver using GPIO — active_low or active_high
pub fn ButtonDriver(comptime gpio_pin: u32, comptime active_low: bool) type {
    return struct {
        const Self = @This();
        initialized: bool = false,

        pub fn init() !Self {
            armino.gpio.enableInput(gpio_pin) catch return error.InitFailed;
            if (active_low) {
                armino.gpio.pullUp(gpio_pin) catch {};
            }
            return .{ .initialized = true };
        }

        pub fn deinit(self: *Self) void {
            self.initialized = false;
        }

        pub fn isPressed(_: *const Self) bool {
            const level = armino.gpio.getInput(gpio_pin);
            return if (active_low) !level else level;
        }
    };
}
