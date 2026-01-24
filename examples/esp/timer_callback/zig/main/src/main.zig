//! Hardware Timer Callback Example - Zig Version
//!
//! Demonstrates hardware timer (GPTimer) with interrupt callback:
//! - Create 1 second periodic timer
//! - Toggle LED state in timer callback (ISR-safe)
//! - Update LED in main loop (not ISR)
//! - Count timer ticks
//!
//! Uses GPTimer for precise timing independent of FreeRTOS tick.

const std = @import("std");
const idf = @import("idf");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

const LED_GPIO: idf.gpio.Pin = 48;

// Global state for timer callback
// Note: For single-writer (ISR) / single-reader (main loop) scenario
// simple variables are sufficient on ESP32
var tick_count: u32 = 0;
var led_state: bool = false;
var led_changed: bool = false;

/// Timer alarm callback - runs in ISR context
/// IMPORTANT: Only do minimal work here - no blocking calls!
fn timerCallback(
    timer: ?*anyopaque,
    event: *const idf.timer.AlarmEventData,
    user_data: ?*anyopaque,
) callconv(.c) bool {
    _ = timer;
    _ = event;
    _ = user_data;

    // Only update flags - ISR safe
    tick_count += 1;
    led_state = !led_state;
    led_changed = true;

    return false; // Don't yield to higher priority task
}

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("Hardware Timer Example - Zig Version", .{});
    std.log.info("==========================================", .{});

    // Initialize LED strip
    var led_strip = idf.LedStrip.init(
        .{ .strip_gpio_num = LED_GPIO, .max_leds = 1 },
        .{ .resolution_hz = 10_000_000 },
    ) catch |err| {
        std.log.err("Failed to initialize LED strip: {}", .{err});
        return;
    };
    defer led_strip.deinit();

    led_strip.clear() catch {};

    // Create hardware timer
    // Resolution: 1MHz (1us per tick)
    var timer = idf.timer.Timer.init(1_000_000) catch |err| {
        std.log.err("Failed to create timer: {}", .{err});
        return;
    };

    // Set alarm for 1 second with auto-reload
    timer.setAlarm(1_000_000, true) catch |err| {
        std.log.err("Failed to set alarm: {}", .{err});
        return;
    };

    // Register callback
    timer.registerCallback(timerCallback, null) catch |err| {
        std.log.err("Failed to register callback: {}", .{err});
        return;
    };

    // Enable and start timer
    timer.enable() catch |err| {
        std.log.err("Failed to enable timer: {}", .{err});
        return;
    };

    timer.start() catch |err| {
        std.log.err("Failed to start timer: {}", .{err});
        return;
    };

    std.log.info("Timer started! LED toggles every 1 second", .{});
    std.log.info("Timer resolution: 1MHz (1us per tick)", .{});

    // Main loop - handle LED updates (not in ISR!)
    while (true) {
        if (led_changed) {
            led_changed = false;

            // Update LED - safe in main loop context
            if (led_state) {
                led_strip.setPixelAndRefresh(0, 32, 0, 0) catch {};
            } else {
                led_strip.clear() catch {};
            }

            std.log.info("Timer tick #{}, LED={s}", .{
                tick_count,
                if (led_state) "ON" else "OFF",
            });
        }
        idf.delayMs(10);
    }
}
