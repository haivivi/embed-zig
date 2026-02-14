//! e2e: hal/led_strip — Verify WS2812 LED strip driver
//!
//! Tests:
//!   1. Driver init/deinit without crash
//!   2. setPixel + refresh (set red, then clear)
//!   3. clear works

const platform = @import("platform.zig");
const log = platform.log;
const LedDriver = platform.LedDriver;
const hal = @import("hal");

fn runTests() !void {
    log.info("[e2e] START: hal/led_strip", .{});

    // Test 1: init/deinit
    var driver = LedDriver.init() catch |err| {
        log.err("[e2e] FAIL: hal/led_strip/init — {}", .{err});
        return error.LedInitFailed;
    };
    defer driver.deinit();
    log.info("[e2e] PASS: hal/led_strip/init — {} pixels", .{driver.getPixelCount()});

    // Test 2: setPixel + refresh (set to red)
    {
        driver.setPixel(0, .{ .r = 255, .g = 0, .b = 0 });
        driver.refresh();
        platform.time.sleepMs(100); // visible flash
        log.info("[e2e] PASS: hal/led_strip/setPixel — red", .{});
    }

    // Test 3: clear
    {
        driver.clear();
        log.info("[e2e] PASS: hal/led_strip/clear", .{});
    }

    log.info("[e2e] PASS: hal/led_strip", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: hal/led_strip — {}", .{err});
    };
}

test "e2e: hal/led_strip" {
    try runTests();
}
