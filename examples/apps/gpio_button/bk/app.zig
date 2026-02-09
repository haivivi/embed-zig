//! GPIO Button Test — BK7258
//!
//! Polls a GPIO input pin for button presses.
//! BK7258 dev board buttons: K1, K3, K4, K5, K6 (exact GPIO TBD)

const bk = @import("bk");
const armino = bk.armino;

// Button GPIO — adjust based on your board's schematic
const BUTTON_GPIO: u32 = 22; // Common GPIO for button on BK dev boards

export fn zig_main() void {
    armino.log.info("ZIG", "==========================================");
    armino.log.info("ZIG", "       GPIO Button Test (BK7258)");
    armino.log.info("ZIG", "==========================================");
    armino.log.logFmt("ZIG", "Button GPIO: {d}", .{BUTTON_GPIO});

    // Configure button pin as input with pull-up
    armino.gpio.enableInput(BUTTON_GPIO) catch {
        armino.log.err("ZIG", "GPIO input enable failed");
        return;
    };
    armino.gpio.pullUp(BUTTON_GPIO) catch {};

    armino.log.info("ZIG", "Polling button... (press to see state change)");

    var last_state: bool = true; // pull-up = default high
    var press_count: u32 = 0;

    while (true) {
        const state = armino.gpio.getInput(BUTTON_GPIO);
        if (state != last_state) {
            if (!state) { // Button pressed (active low)
                press_count += 1;
                armino.log.logFmt("ZIG", "Button PRESSED (count={d})", .{press_count});
            } else {
                armino.log.info("ZIG", "Button released");
            }
            last_state = state;
        }
        armino.time.sleepMs(20); // Debounce
    }
}
