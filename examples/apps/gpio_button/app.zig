//! GPIO Button Example - Platform Independent
//!
//! Press boot button to toggle LED.

const hal = @import("hal");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

var led_state: bool = false;

pub fn run() void {
    log.info("GPIO Button Example - HAL v5", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("Ready! Press boot button to toggle LED", .{});

    while (true) {
        b.poll();

        while (b.nextEvent()) |event| {
            switch (event) {
                .button => |btn| {
                    switch (btn.action) {
                        .press => {
                            led_state = !led_state;
                            if (led_state) {
                                // Bright green for better visibility
                                b.rgb_leds.setColor(hal.Color.rgb(0, 255, 0));
                            } else {
                                b.rgb_leds.clear();
                            }
                            b.rgb_leds.refresh();
                            log.info("LED {s}", .{if (led_state) "ON" else "OFF"});
                        },
                        .long_press => {
                            b.rgb_leds.setColor(hal.Color.red);
                            b.rgb_leds.refresh();
                            log.info("Long press!", .{});
                        },
                        .double_click => {
                            b.rgb_leds.setColor(hal.Color.blue);
                            b.rgb_leds.refresh();
                            log.info("Double click!", .{});
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        Board.time.sleepMs(10);
    }
}
