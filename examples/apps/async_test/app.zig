//! Async Task Test - Tests go() and WaitGroup with TLS callbacks
//!
//! This example verifies:
//! 1. go() fire-and-forget tasks execute and clean up properly
//! 2. WaitGroup.go() tasks trigger done() via TLS deletion callback
//! 3. Multiple concurrent tasks work correctly

const std = @import("std");
const esp = @import("esp");

const idf = esp.idf;
const async_mod = idf.async_;
const heap = idf.heap;

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const BUILD_TAG = "async_test_tls_callback";

// ============================================================================
// Test 1: Fire-and-forget task
// ============================================================================

const FireForgetCtx = struct {
    id: u32,
    delay_ms: u32,
};

fn fireForgetTask(ctx: ?*anyopaque) callconv(.c) void {
    const ff_ctx: *FireForgetCtx = @ptrCast(@alignCast(ctx));
    log.info("[FireForget #{}] Started, will sleep {}ms", .{ ff_ctx.id, ff_ctx.delay_ms });
    idf.time.sleepMs(ff_ctx.delay_ms);
    log.info("[FireForget #{}] Completed!", .{ff_ctx.id});
}

fn testFireForget() !void {
    log.info("=== Test 1: Fire-and-forget tasks ===", .{});

    // Create contexts on heap (tasks will outlive this function)
    const ctx1 = try heap.psram.create(FireForgetCtx);
    ctx1.* = .{ .id = 1, .delay_ms = 500 };

    const ctx2 = try heap.psram.create(FireForgetCtx);
    ctx2.* = .{ .id = 2, .delay_ms = 1000 };

    // Spawn fire-and-forget tasks
    try async_mod.go(heap.psram, "ff_task1", fireForgetTask, ctx1, .{
        .stack_size = 4096,
        .priority = 10,
    });
    log.info("Spawned fire-forget task #1", .{});

    try async_mod.go(heap.psram, "ff_task2", fireForgetTask, ctx2, .{
        .stack_size = 4096,
        .priority = 10,
    });
    log.info("Spawned fire-forget task #2", .{});

    // Wait a bit for tasks to complete (they're fire-and-forget, we can't wait)
    log.info("Main thread continuing... tasks run in background", .{});
    idf.time.sleepMs(1500);
    log.info("Fire-and-forget test done (tasks should have completed)", .{});
}

// ============================================================================
// Test 2: WaitGroup with single task
// ============================================================================

const WaitGroupCtx = struct {
    id: u32,
    delay_ms: u32,
    completed: bool = false,
};

fn waitGroupTask(ctx: ?*anyopaque) callconv(.c) void {
    const wg_ctx: *WaitGroupCtx = @ptrCast(@alignCast(ctx));
    log.info("[WaitGroup #{}] Started, will sleep {}ms", .{ wg_ctx.id, wg_ctx.delay_ms });
    idf.time.sleepMs(wg_ctx.delay_ms);
    wg_ctx.completed = true;
    log.info("[WaitGroup #{}] Completed!", .{wg_ctx.id});
    // Note: done() is called by TLS deletion callback, not here
}

fn testWaitGroupSingle() !void {
    log.info("=== Test 2: WaitGroup single task ===", .{});

    var wg = async_mod.WaitGroup.init(heap.psram);
    defer wg.deinit();

    var ctx = WaitGroupCtx{ .id = 1, .delay_ms = 500 };

    const start_time = idf.time.nowMs();
    log.info("Spawning WaitGroup task...", .{});

    try wg.go(heap.iram, "wg_task1", waitGroupTask, &ctx, .{
        .stack_size = 4096,
        .priority = 15,
    });

    log.info("Waiting for task to complete...", .{});
    wg.wait();

    const elapsed = idf.time.nowMs() - start_time;
    log.info("WaitGroup.wait() returned after {}ms", .{elapsed});
    log.info("Task completed flag: {}", .{ctx.completed});

    if (ctx.completed and elapsed >= 400) {
        log.info("TEST 2 PASSED: TLS callback correctly triggered done()", .{});
    } else {
        log.err("TEST 2 FAILED: completed={}, elapsed={}ms", .{ ctx.completed, elapsed });
    }
}

// ============================================================================
// Test 3: WaitGroup with multiple concurrent tasks
// ============================================================================

fn testWaitGroupMultiple() !void {
    log.info("=== Test 3: WaitGroup multiple tasks ===", .{});

    var wg = async_mod.WaitGroup.init(heap.psram);
    defer wg.deinit();

    var ctx1 = WaitGroupCtx{ .id = 1, .delay_ms = 300 };
    var ctx2 = WaitGroupCtx{ .id = 2, .delay_ms = 500 };
    var ctx3 = WaitGroupCtx{ .id = 3, .delay_ms = 200 };

    const start_time = idf.time.nowMs();
    log.info("Spawning 3 WaitGroup tasks...", .{});

    // Spawn all tasks
    try wg.go(heap.iram, "wg_multi1", waitGroupTask, &ctx1, .{
        .stack_size = 4096,
        .priority = 15,
    });
    try wg.go(heap.iram, "wg_multi2", waitGroupTask, &ctx2, .{
        .stack_size = 4096,
        .priority = 15,
    });
    try wg.go(heap.iram, "wg_multi3", waitGroupTask, &ctx3, .{
        .stack_size = 4096,
        .priority = 15,
    });

    log.info("All tasks spawned, waiting...", .{});
    wg.wait();

    const elapsed = idf.time.nowMs() - start_time;
    log.info("WaitGroup.wait() returned after {}ms", .{elapsed});
    log.info("Task 1 completed: {}", .{ctx1.completed});
    log.info("Task 2 completed: {}", .{ctx2.completed});
    log.info("Task 3 completed: {}", .{ctx3.completed});

    const all_completed = ctx1.completed and ctx2.completed and ctx3.completed;
    // Should take ~500ms (max delay), not 1000ms (sum of delays)
    if (all_completed and elapsed >= 400 and elapsed < 800) {
        log.info("TEST 3 PASSED: All tasks completed, ran concurrently", .{});
    } else {
        log.err("TEST 3 FAILED: all_completed={}, elapsed={}ms", .{ all_completed, elapsed });
    }
}

// ============================================================================
// Main entry point
// ============================================================================

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("Async Task Test - TLS Callback Verification", .{});
    log.info("Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});
    log.info("Board:     {s}", .{Board.meta.id});
    log.info("==========================================", .{});

    // Initialize board (minimal, just for logging)
    var board: Board = undefined;
    board.init() catch |err| {
        log.err("Failed to initialize board: {}", .{err});
        return;
    };
    defer board.deinit();

    log.info("Starting async tests...", .{});
    log.info("", .{});

    // Run tests
    testFireForget() catch |err| {
        log.err("Test 1 failed: {}", .{err});
    };

    log.info("", .{});

    testWaitGroupSingle() catch |err| {
        log.err("Test 2 failed: {}", .{err});
    };

    log.info("", .{});

    testWaitGroupMultiple() catch |err| {
        log.err("Test 3 failed: {}", .{err});
    };

    log.info("", .{});
    log.info("==========================================", .{});
    log.info("All tests completed!", .{});
    log.info("==========================================", .{});

    // Keep running so we can see logs
    while (true) {
        Board.time.sleepMs(5000);
        log.info("Still alive... uptime={}ms", .{board.uptime()});
    }
}
