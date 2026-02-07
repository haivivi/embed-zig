//! ESP PWM Implementation (using LEDC)
//!
//! Uses ESP-IDF's LEDC peripheral for PWM output.

const std = @import("std");
const ledc_mod = @import("ledc/ledc.zig");

pub const Config = struct {
    /// GPIO pin number
    gpio: u8,
    /// PWM frequency in Hz
    freq_hz: u32 = 5000,
    /// Resolution in bits (determines duty cycle precision)
    resolution_bits: u8 = 10,
};

/// ESP PWM using LEDC
pub const Pwm = struct {
    const Self = @This();

    ledc: ledc_mod.Ledc,
    max_duty: u32,

    pub fn init(config: Config) !Self {
        const ledc = try ledc_mod.Ledc.init(config.gpio, config.freq_hz, config.resolution_bits);
        const shift: u5 = @intCast(config.resolution_bits);
        const max_duty: u32 = (@as(u32, 1) << shift) - 1;
        return .{ .ledc = ledc, .max_duty = max_duty };
    }

    pub fn deinit(self: *Self) void {
        self.ledc.deinit();
    }

    /// Set duty cycle (0-65535 normalized)
    pub fn setDuty(self: *Self, duty: u16) void {
        // Convert from 16-bit to LEDC resolution
        const scaled: u32 = (@as(u32, duty) * self.max_duty) / 65535;
        self.ledc.setDuty(scaled) catch {};
    }

    /// Get current duty cycle (0-65535)
    pub fn getDuty(self: *const Self) u16 {
        const current = self.ledc.getDuty();
        // Convert back to 16-bit
        return @intCast((current * 65535) / self.max_duty);
    }

    /// Fade to target duty over duration
    pub fn fade(self: *Self, target: u16, duration_ms: u32) void {
        const scaled: u32 = (@as(u32, target) * self.max_duty) / 65535;
        self.ledc.fade(scaled, duration_ms) catch {};
    }

    // ================================================================
    // Convenience methods
    // ================================================================

    /// Set duty cycle as percentage (0-100)
    pub fn setPercent(self: *Self, percent: u8) void {
        const clamped = @min(percent, 100);
        const duty: u16 = @intCast((@as(u32, clamped) * 65535) / 100);
        self.setDuty(duty);
    }

    /// Get duty cycle as percentage (0-100)
    pub fn getPercent(self: *const Self) u8 {
        const duty = self.getDuty();
        return @intCast((@as(u32, duty) * 100) / 65535);
    }

    /// Fade to percentage over duration
    pub fn fadePercent(self: *Self, percent: u8, duration_ms: u32) void {
        const clamped = @min(percent, 100);
        const target: u16 = @intCast((@as(u32, clamped) * 65535) / 100);
        self.fade(target, duration_ms);
    }

    /// Turn on (100% duty)
    pub fn on(self: *Self) void {
        self.setDuty(65535);
    }

    /// Turn off (0% duty)
    pub fn off(self: *Self) void {
        self.setDuty(0);
    }
};
