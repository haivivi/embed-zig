//! e2e: trait/time — Verify sleepMs and getTimeMs
//!
//! Tests:
//!   1. sleepMs(10) completes without crash
//!   2. getTimeMs() returns monotonically increasing values
//!   3. sleepMs duration is within tolerance (50ms sleep → 40-200ms elapsed)
//!
//! This file is IDENTICAL for all platforms. platform.zig → board module handles switching.

const platform = @import("platform.zig");
const log = platform.log;
const time = platform.time;

fn runTests() !void {
    log.info("[e2e] START: trait/time", .{});

    // Test 1: sleepMs completes without crash
    time.sleepMs(10);
    log.info("[e2e] PASS: trait/time/sleepMs", .{});

    // Test 2: nowMs returns monotonically increasing values
    {
        const t1 = time.nowMs();
        time.sleepMs(10);
        const t2 = time.nowMs();

        if (t2 <= t1) {
            log.err("[e2e] FAIL: trait/time/monotonic — t1={}, t2={}", .{ t1, t2 });
            return error.TimeNotMonotonic;
        }
        log.info("[e2e] PASS: trait/time/monotonic — delta={}ms", .{t2 - t1});
    }

    // Test 3: sleepMs(50) takes roughly 50ms (allow 40-200ms for scheduler jitter)
    {
        const before = time.nowMs();
        time.sleepMs(50);
        const after = time.nowMs();
        const elapsed = after - before;

        if (elapsed < 40) {
            log.err("[e2e] FAIL: trait/time/duration — slept 50ms but only {}ms elapsed", .{elapsed});
            return error.SleepTooShort;
        }
        if (elapsed > 200) {
            log.err("[e2e] FAIL: trait/time/duration — slept 50ms but {}ms elapsed", .{elapsed});
            return error.SleepTooLong;
        }
        log.info("[e2e] PASS: trait/time/duration — 50ms sleep took {}ms", .{elapsed});
    }

    log.info("[e2e] PASS: trait/time", .{});
}

/// ESP entry point (called by esp_zig_app framework)
pub fn run(_: anytype) void {
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/time — {}", .{err});
    };
}

// std test entry (only compiled by zig test)
test "e2e: trait/time" {
    try runTests();
}
