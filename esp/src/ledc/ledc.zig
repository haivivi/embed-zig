//! LEDC (LED Controller) PWM driver
//!
//! Example:
//! ```zig
//! const ledc = idf.ledc;
//!
//! // Initialize PWM on GPIO 48, 5kHz, 10-bit resolution
//! try ledc.init(48, 5000, 10);
//!
//! // Set duty cycle (0-1023 for 10-bit)
//! try ledc.setDuty(512);
//!
//! // Fade to target duty over time
//! try ledc.fade(1023, 2000); // Fade to max in 2 seconds
//! ```

const std = @import("std");
const sys = @import("../sys.zig");

const c = @cImport({
    @cInclude("driver/ledc.h");
});

// Extern declarations for helper functions
extern fn ledc_init_simple(gpio_num: c_int, freq_hz: u32, duty_resolution_bits: u8) c_int;
extern fn ledc_fade_simple(speed_mode: c_int, channel: c_int, target_duty: u32, fade_time_ms: c_int) c_int;

/// Speed mode
pub const SpeedMode = enum(c_int) {
    low_speed = 0,
    high_speed = 1,
};

/// Timer selection
pub const Timer = enum(c_int) {
    timer_0 = 0,
    timer_1 = 1,
    timer_2 = 2,
    timer_3 = 3,
};

/// Channel selection
pub const Channel = enum(c_int) {
    channel_0 = 0,
    channel_1 = 1,
    channel_2 = 2,
    channel_3 = 3,
    channel_4 = 4,
    channel_5 = 5,
    channel_6 = 6,
    channel_7 = 7,
};

/// LEDC PWM wrapper
pub const Ledc = struct {
    gpio_num: i32,
    speed_mode: SpeedMode,
    channel: Channel,
    timer: Timer,

    /// Initialize LEDC PWM on a GPIO pin
    /// freq_hz: PWM frequency in Hz (e.g., 5000 for 5kHz)
    /// duty_resolution_bits: Duty resolution in bits (e.g., 10 for 0-1023)
    pub fn init(gpio_num: u8, freq_hz: u32, duty_resolution_bits: u8) !Ledc {
        const err = ledc_init_simple(
            @intCast(gpio_num),
            freq_hz,
            duty_resolution_bits,
        );
        try sys.espErrToZig(err);

        return Ledc{
            .gpio_num = @intCast(gpio_num),
            .speed_mode = .low_speed,
            .channel = .channel_0,
            .timer = .timer_0,
        };
    }

    /// Set duty cycle (0 to max based on resolution)
    pub fn setDuty(self: Ledc, duty: u32) !void {
        const err = c.ledc_set_duty(
            @intCast(@intFromEnum(self.speed_mode)),
            @intCast(@intFromEnum(self.channel)),
            duty,
        );
        try sys.espErrToZig(err);

        const err2 = c.ledc_update_duty(
            @intCast(@intFromEnum(self.speed_mode)),
            @intCast(@intFromEnum(self.channel)),
        );
        try sys.espErrToZig(err2);
    }

    /// Get current duty cycle
    pub fn getDuty(self: Ledc) u32 {
        return c.ledc_get_duty(
            @intCast(@intFromEnum(self.speed_mode)),
            @intCast(@intFromEnum(self.channel)),
        );
    }

    /// Fade to target duty over specified time (ms)
    pub fn fade(self: Ledc, target_duty: u32, fade_time_ms: u32) !void {
        const err = ledc_fade_simple(
            @intCast(@intFromEnum(self.speed_mode)),
            @intCast(@intFromEnum(self.channel)),
            target_duty,
            @intCast(fade_time_ms),
        );
        try sys.espErrToZig(err);
    }

    /// Stop PWM output
    pub fn stop(self: Ledc) !void {
        const err = c.ledc_stop(
            @intCast(@intFromEnum(self.speed_mode)),
            @intCast(@intFromEnum(self.channel)),
            0,
        );
        try sys.espErrToZig(err);
    }
};
