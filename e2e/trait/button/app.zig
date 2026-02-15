//! e2e: hal/button — Verify Boot button driver (GPIO0)
//!
//! Tests:
//!   1. Driver init/deinit without crash
//!   2. isPressed returns false (nobody pressing it during test)

const platform = @import("platform.zig");
const log = platform.log;
const ButtonDriver = platform.ButtonDriver;

fn runTests() !void {
    log.info("[e2e] START: hal/button", .{});

    // Test 1: init/deinit
    var driver = ButtonDriver.init() catch |err| {
        log.err("[e2e] FAIL: hal/button/init — {}", .{err});
        return error.ButtonInitFailed;
    };
    defer driver.deinit();
    log.info("[e2e] PASS: hal/button/init", .{});

    // Test 2: isPressed — should be false (no human pressing during e2e)
    {
        const pressed = driver.isPressed();
        if (pressed) {
            // Not fatal — someone might be holding the button
            log.warn("[e2e] WARN: hal/button/read — button is pressed (expected false)", .{});
        } else {
            log.info("[e2e] PASS: hal/button/read — not pressed (expected)", .{});
        }
    }

    log.info("[e2e] PASS: hal/button", .{});
}

pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: hal/button — {}", .{err});
    };
}

test "e2e: hal/button" {
    try runTests();
}
