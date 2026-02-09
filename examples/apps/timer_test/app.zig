//! Timer Test — ESP platform (hardware timer via esp_timer)
//!
//! Demonstrates lib/pkg/timer with hardware backend on ESP32.
//! Schedules callbacks using esp_timer, verifies they fire correctly.

const std = @import("std");
const hal = @import("hal");
const esp = @import("esp");
const timer_pkg = @import("timer");

const idf = esp.idf;
const impl = esp.impl;
const EspRt = idf.runtime;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const HwTimer = hal.timer.from(impl.timer.timer_spec);
const Timer = timer_pkg.TimerService(EspRt, HwTimer);
const TimerHandle = timer_pkg.TimerHandle;

// ============================================================================
// Test 1: Single timer fires
// ============================================================================

var test1_fired: bool = false;

fn test1Callback(_: ?*anyopaque) void {
    test1_fired = true;
}

fn testSingleTimer(ts: *Timer) void {
    log.info("=== Test 1: Single timer (100ms) ===", .{});

    test1_fired = false;
    _ = ts.schedule(100, test1Callback, null);

    // Wait for timer to fire
    idf.time.sleepMs(200);

    if (test1_fired) {
        log.info("  PASSED: timer fired", .{});
    } else {
        log.err("  FAILED: timer did not fire", .{});
    }
}

// ============================================================================
// Test 2: Cancel before fire
// ============================================================================

var test2_fired: bool = false;

fn test2Callback(_: ?*anyopaque) void {
    test2_fired = true;
}

fn testCancel(ts: *Timer) void {
    log.info("=== Test 2: Cancel before fire ===", .{});

    test2_fired = false;
    const handle = ts.schedule(200, test2Callback, null);
    log.info("  scheduled 200ms timer, handle.id={d}", .{handle.id});

    idf.time.sleepMs(50);
    ts.cancel(handle);
    log.info("  cancelled after 50ms", .{});

    idf.time.sleepMs(300);

    if (!test2_fired) {
        log.info("  PASSED: cancelled timer did not fire", .{});
    } else {
        log.err("  FAILED: cancelled timer fired", .{});
    }
}

// ============================================================================
// Test 3: Multiple timers with context
// ============================================================================

const CounterCtx = struct {
    count: u32 = 0,
};

fn counterCallback(raw: ?*anyopaque) void {
    const ctx: *CounterCtx = @ptrCast(@alignCast(raw orelse return));
    ctx.count += 1;
}

fn testMultiple(ts: *Timer) void {
    log.info("=== Test 3: Multiple timers ===", .{});

    var ctx_a = CounterCtx{};
    var ctx_b = CounterCtx{};

    _ = ts.schedule(50, counterCallback, &ctx_a);
    _ = ts.schedule(100, counterCallback, &ctx_a);
    _ = ts.schedule(75, counterCallback, &ctx_b);

    log.info("  scheduled: A@50ms, A@100ms, B@75ms", .{});

    idf.time.sleepMs(200);

    log.info("  A fired {d} times, B fired {d} times", .{ ctx_a.count, ctx_b.count });

    if (ctx_a.count == 2 and ctx_b.count == 1) {
        log.info("  PASSED", .{});
    } else {
        log.err("  FAILED: expected A=2, B=1", .{});
    }
}

// ============================================================================
// Main entry
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Timer Test (ESP, hardware esp_timer)", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("==========================================", .{});

    // Init board
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to init board: {}", .{err});
        return;
    };
    defer board.deinit();

    // Init HW timer driver + TimerService
    var timer_driver = impl.EspTimerDriver.init();
    defer timer_driver.deinit();
    var hw_timer = HwTimer.init(&timer_driver);
    var ts = Timer.initHw(&hw_timer);
    defer ts.deinit();

    // Run tests
    testSingleTimer(&ts);
    log.info("", .{});

    testCancel(&ts);
    log.info("", .{});

    testMultiple(&ts);
    log.info("", .{});

    log.info("==========================================", .{});
    log.info("All tests completed!", .{});
    log.info("==========================================", .{});

    while (true) {
        Board.time.sleepMs(5000);
        log.info("alive, uptime={}ms", .{board.uptime()});
    }
}
