//! PWM Fade Example - Platform Independent
//!
//! Demonstrates PWM-controlled LED with hardware fade:
//! - Fade LED brightness up and down (breathing effect)
//! - Uses HAL PwmLed abstraction

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const FADE_TIME_MS: u32 = 2000;

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("PWM Fade Example - HAL v5", .{});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Board initialized", .{});
    log.info("Fade time: {} ms", .{FADE_TIME_MS});

    var cycle: u32 = 0;

    while (true) {
        cycle += 1;

        // Fade in to 100%
        log.info("Cycle {}: Fading in...", .{cycle});
        board.led.fadeIn(FADE_TIME_MS);

        // Small delay at max brightness
        Board.time.sleepMs(200);

        // Fade out to 0%
        log.info("Cycle {}: Fading out...", .{cycle});
        board.led.fadeOut(FADE_TIME_MS);

        // Small delay at min brightness
        Board.time.sleepMs(200);
    }
}
