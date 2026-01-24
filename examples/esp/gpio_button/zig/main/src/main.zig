//! GPIO Button Example - Zig Version
//!
//! Demonstrates GPIO input/output:
//! - Read Boot button state (GPIO0, active low)
//! - Control onboard RGB LED (GPIO48)
//! - Button press toggles LED state
//!
//! Hardware:
//! - Boot button on GPIO0 (active low, has internal pull-up)
//! - WS2812 RGB LED on GPIO48

const std = @import("std");
const idf = @import("idf");

pub const std_options = std.Options{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

const BOOT_BUTTON_GPIO: idf.gpio.Pin = 0;
const LED_GPIO: idf.gpio.Pin = 48;

var led_state: bool = false;

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("GPIO Button Example - Zig Version", .{});
    std.log.info("==========================================", .{});
    std.log.info("Press Boot button to toggle LED", .{});

    // Initialize LED strip for RGB LED
    var strip = idf.LedStrip.init(
        .{ .strip_gpio_num = LED_GPIO, .max_leds = 1 },
        .{ .resolution_hz = 10_000_000 },
    ) catch |err| {
        std.log.err("Failed to initialize LED strip: {}", .{err});
        return;
    };
    defer strip.deinit();

    strip.clear() catch {};

    // Configure Boot button as input with pull-up
    idf.gpio.configInput(BOOT_BUTTON_GPIO, true) catch |err| {
        std.log.err("Failed to configure button GPIO: {}", .{err});
        return;
    };

    std.log.info("GPIO initialized. Button=GPIO{}, LED=GPIO{}", .{ BOOT_BUTTON_GPIO, LED_GPIO });

    var last_button_state: u1 = 1; // Button is active low, so 1 = not pressed
    var press_count: u32 = 0;

    while (true) {
        // Read button state (active low)
        const button_state = idf.gpio.getLevel(BOOT_BUTTON_GPIO);

        // Detect button press (falling edge: 1 -> 0)
        if (last_button_state == 1 and button_state == 0) {
            press_count += 1;
            led_state = !led_state;

            std.log.info("Button pressed! Count={}, LED={s}", .{
                press_count,
                if (led_state) "ON" else "OFF",
            });

            if (led_state) {
                // LED on: white color
                strip.setPixelAndRefresh(0, 32, 32, 32) catch {};
            } else {
                // LED off
                strip.clear() catch {};
            }

            // Simple debounce
            idf.delayMs(50);
        }

        last_button_state = button_state;
        idf.delayMs(10);
    }
}
