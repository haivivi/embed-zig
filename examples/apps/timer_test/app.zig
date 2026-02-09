//! Timer Test — ESP platform (software timer)
//!
//! Demonstrates lib/pkg/timer on ESP32. Uses a FreeRTOS task
//! to drive advance(1) every 1ms.

const std = @import("std");
const hal = @import("hal");
const esp = @import("esp");
const timer_pkg = @import("timer");

const idf = esp.idf;
const EspRt = idf.runtime;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const Timer = timer_pkg.TimerService(EspRt);
const TimerHandle = timer_pkg.TimerHandle;

// ============================================================================
// Timer tick task — drives advance(1) every 1ms
// ============================================================================

var g_timer: *Timer = undefined;
var g_running: bool = true;

fn timerTickTask(ctx: ?*anyopaque) void {
    _ = ctx;
    while (g_running) {
        _ = g_timer.advance(1);
        idf.time.sleepMs(1);
    }
}

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
    log.info("  scheduled 200ms timer", .{});

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
    log.info("Timer Test (ESP, software timer)", .{});
    log.info("Board: {s}", .{Board.meta.id});
    log.info("==========================================", .{});

    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to init board: {}", .{err});
        return;
    };
    defer board.deinit();

    // Init software timer + tick task
    var ts = Timer.init(idf.heap.psram);
    defer ts.deinit();
    g_timer = &ts;

    EspRt.spawn("timer_tick", timerTickTask, null, .{
        .stack_size = 4096,
        .priority = 10,
    }) catch |err| {
        log.err("Failed to spawn tick task: {}", .{err});
        return;
    };

    // Run tests
    testSingleTimer(&ts);
    log.info("", .{});

    testCancel(&ts);
    log.info("", .{});

    testMultiple(&ts);
    log.info("", .{});

    g_running = false;

    log.info("==========================================", .{});
    log.info("All tests completed!", .{});
    log.info("==========================================", .{});

    while (true) {
        Board.time.sleepMs(5000);
        log.info("alive, uptime={}ms", .{board.uptime()});
    }
}
