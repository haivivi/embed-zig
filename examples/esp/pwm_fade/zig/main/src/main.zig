//! PWM Fade Example - Zig Version
//!
//! Demonstrates LEDC (LED Controller) PWM with hardware fade:
//! - Initialize PWM on onboard LED (GPIO 48)
//! - Fade LED brightness up and down (breathing effect)
//!
//! Uses LEDC hardware fade for smooth transitions.

const std = @import("std");
const idf = @import("esp");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

const LED_GPIO: u8 = 48;
const PWM_FREQ_HZ: u32 = 5000;
const PWM_RESOLUTION_BITS: u8 = 10; // 0-1023
const MAX_DUTY: u32 = (1 << PWM_RESOLUTION_BITS) - 1; // 1023
const FADE_TIME_MS: u32 = 2000;

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("PWM Fade Example - Zig Version", .{});
    std.log.info("==========================================", .{});

    // Initialize LEDC PWM
    var ledc = idf.ledc.Ledc.init(LED_GPIO, PWM_FREQ_HZ, PWM_RESOLUTION_BITS) catch |err| {
        std.log.err("Failed to initialize LEDC: {}", .{err});
        return;
    };

    std.log.info("LEDC initialized on GPIO {}", .{LED_GPIO});
    std.log.info("Frequency: {} Hz, Resolution: {} bits (0-{})", .{
        PWM_FREQ_HZ,
        PWM_RESOLUTION_BITS,
        MAX_DUTY,
    });
    std.log.info("Fade time: {} ms", .{FADE_TIME_MS});

    var cycle: u32 = 0;

    while (true) {
        cycle += 1;

        // Fade up
        std.log.info("Cycle {}: Fading up...", .{cycle});
        ledc.fade(MAX_DUTY, FADE_TIME_MS) catch |err| {
            std.log.err("Fade up failed: {}", .{err});
        };

        // Small delay at max brightness
        idf.delayMs(200);

        // Fade down
        std.log.info("Cycle {}: Fading down...", .{cycle});
        ledc.fade(0, FADE_TIME_MS) catch |err| {
            std.log.err("Fade down failed: {}", .{err});
        };

        // Small delay at min brightness
        idf.delayMs(200);
    }
}
