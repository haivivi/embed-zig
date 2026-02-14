//! WebSim Single LED Driver (PWM-style, duty cycle 0-65535)
//!
//! Simulates a single-color LED (like onboard status LED).
//! Stores duty value in SharedState for JS to render.

const state_mod = @import("state.zig");
const shared = &state_mod.state;

pub const LedSingleDriver = struct {
    const Self = @This();

    duty: u16 = 0,

    pub fn init() !Self {
        shared.addLog("WebSim: Single LED initialized");
        return .{};
    }

    pub fn deinit(_: *Self) void {}

    /// Set PWM duty cycle (0 = off, 65535 = full brightness)
    pub fn setDuty(self: *Self, duty: u16) void {
        self.duty = duty;
        // Map duty to LED color (white with variable brightness)
        const brightness: u8 = @intCast(duty / 257);
        if (brightness > 0) {
            shared.led_colors[0] = .{ .r = brightness, .g = brightness, .b = brightness };
        } else {
            shared.led_colors[0] = .{};
        }
    }

    /// Get current duty cycle
    pub fn getDuty(self: *const Self) u16 {
        return self.duty;
    }

    /// Fade (instant — no smooth transition in sim)
    pub fn fade(self: *Self, target: u16, _: u32) void {
        self.setDuty(target);
    }
};
