//! WebSim WASM entry point for gpio_button
//!
//! Adapts the gpio_button app to cooperative stepping:
//! - init(): initialize board
//! - step(): one iteration of the main loop (poll + update)
//!
//! JS calls these via requestAnimationFrame.

const hal = @import("hal");
const websim = @import("websim");
const platform = @import("platform.zig");

const Board = platform.Board;

var board: Board = undefined;
var led_state: bool = false;
var initialized: bool = false;

/// App module interface for websim.wasm.exportAll
pub fn init() void {
    board.init() catch {
        websim.sal.log.err("Board init failed", .{});
        return;
    };
    initialized = true;
    websim.sal.log.info("GPIO Button Example - WebSim", .{});
    websim.sal.log.info("Click BOOT or press Space", .{});
}

pub fn step() void {
    if (!initialized) return;

    const current_time = board.uptime();
    if (board.button.poll(current_time)) |btn| {
        switch (btn.action) {
            .press => {
                led_state = !led_state;
                if (led_state) {
                    board.rgb_leds.setColor(hal.Color.rgb(0, 255, 0));
                } else {
                    board.rgb_leds.clear();
                }
                board.rgb_leds.refresh();
                websim.sal.log.info("LED {s}", .{if (led_state) "ON" else "OFF"});
            },
            .long_press => {
                board.rgb_leds.setColor(hal.Color.red);
                board.rgb_leds.refresh();
                websim.sal.log.info("Long press!", .{});
            },
            .double_click => {
                board.rgb_leds.setColor(hal.Color.blue);
                board.rgb_leds.refresh();
                websim.sal.log.info("Double click!", .{});
            },
            else => {},
        }
    }
}

// Generate WASM exports
comptime {
    websim.wasm.exportAll(@This());
}
