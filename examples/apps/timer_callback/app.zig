//! Hardware Timer Callback - Platform Independent App
//!
//! Demonstrates hardware timer (GPTimer) with interrupt callback.
//! LED toggled via timer callback, actual update in main loop.

const hal = @import("hal");
const idf = @import("esp");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const BUILD_TAG = "timer_callback_hal_v5";

// Global state for timer callback
var tick_count: u32 = 0;
var led_state: bool = false;
var led_changed: bool = false;

/// Timer alarm callback - runs in ISR context
fn timerCallback(
    _: ?*anyopaque,
    _: *const idf.timer.AlarmEventData,
    _: ?*anyopaque,
) callconv(.c) bool {
    tick_count += 1;
    led_state = !led_state;
    led_changed = true;
    return false;
}

pub fn run() void {
    log.info("==========================================", .{});
    log.info("Hardware Timer Example - HAL v5", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:     {s}", .{Board.meta.id});
    log.info("==========================================", .{});

    // Initialize board (HAL)
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    // Create hardware timer
    var timer = idf.timer.Timer.init(1_000_000) catch |err| {
        log.err("Failed to create timer: {}", .{err});
        return;
    };

    // Set alarm for 1 second with auto-reload
    timer.setAlarm(1_000_000, true) catch |err| {
        log.err("Failed to set alarm: {}", .{err});
        return;
    };

    // Register callback
    timer.registerCallback(timerCallback, null) catch |err| {
        log.err("Failed to register callback: {}", .{err});
        return;
    };

    // Enable and start timer
    timer.enable() catch |err| {
        log.err("Failed to enable timer: {}", .{err});
        return;
    };

    timer.start() catch |err| {
        log.err("Failed to start timer: {}", .{err});
        return;
    };

    log.info("Timer started! LED toggles every 1 second", .{});

    // Main loop - handle LED updates (not in ISR!)
    while (true) {
        if (led_changed) {
            led_changed = false;

            if (led_state) {
                board.rgb_leds.setColor(hal.Color.red.withBrightness(32));
            } else {
                board.rgb_leds.clear();
            }
            board.rgb_leds.refresh();

            log.info("Timer tick #{}, LED={s}, uptime={}ms", .{
                tick_count,
                if (led_state) "ON" else "OFF",
                board.uptime(),
            });
        }
        Board.time.sleepMs(10);
    }
}
