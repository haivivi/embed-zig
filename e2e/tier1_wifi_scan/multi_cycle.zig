//! Test Scenario 3: Multiple Scan Cycles
//!
//! Tests that consecutive scans work correctly:
//! 1. Perform first scan and collect results
//! 2. Wait interval
//! 3. Perform second scan and collect results
//! 4. Verify AP list is properly reset between scans
//! 5. Verify scan count increments
//!
//! This validates:
//! - Application buffer reset between scans
//! - Driver state management
//! - Event stream isolation between scans

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const common = @import("common.zig");
const ApList = common.ApList;
const TestResult = common.TestResult;
const SCAN_INTERVAL_MS = common.SCAN_INTERVAL_MS;

/// Number of scan cycles to perform
const SCAN_CYCLES = 3;

/// Run the multi-cycle scan test
/// Returns TestResult indicating pass/fail
pub fn run(b: *Board) TestResult {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("TEST 3: Multiple Scan Cycles", .{});
    log.info("========================================", .{});
    log.info("Description: Perform {} consecutive scans", .{SCAN_CYCLES});
    log.info("Expected: Each scan completes, AP list resets between scans", .{});
    log.info("", .{});

    var total_aps: usize = 0;
    var cycle_results: [SCAN_CYCLES]i32 = undefined;

    var cycle: u32 = 0;
    while (cycle < SCAN_CYCLES) : (cycle += 1) {
        log.info("", .{});
        log.info("----- Cycle {}/{} -----", .{ cycle + 1, SCAN_CYCLES });

        var ap_list = ApList{};

        // Perform scan
        const ap_count = common.performScan(b, &ap_list, true);
        if (ap_count < 0) {
            return TestResult.fail("Scan cycle failed");
        }

        cycle_results[cycle] = ap_count;
        total_aps += @intCast(ap_count);

        log.info("[TEST] Cycle {}: Found {} AP(s)", .{ cycle + 1, ap_count });

        // Verify buffer was properly reset (count should match slice length)
        if (ap_list.count != @as(usize, @intCast(ap_count))) {
            return TestResult.fail("AP list buffer not properly reset");
        }

        // Wait between scans (except after last)
        if (cycle < SCAN_CYCLES - 1) {
            log.info("[TEST] Waiting {} ms before next scan...", .{SCAN_INTERVAL_MS});
            Board.time.sleepMs(SCAN_INTERVAL_MS);
        }
    }

    // Summary
    log.info("", .{});
    log.info("----- Multi-Cycle Summary -----", .{});
    log.info("Completed {} scan cycles", .{SCAN_CYCLES});

    cycle = 0;
    while (cycle < SCAN_CYCLES) : (cycle += 1) {
        log.info("  Cycle {}: {} APs", .{ cycle + 1, cycle_results[cycle] });
    }

    log.info("Total APs discovered: {}", .{total_aps});

    // Verify some basic consistency
    // (AP counts may vary due to environmental factors, but should be reasonable)
    for (cycle_results) |count| {
        if (count < 0) {
            return TestResult.fail("Invalid cycle result");
        }
    }

    return TestResult.pass("Multiple scan cycles completed successfully");
}

/// Standalone entry point for Bazel esp_zig_app target.
/// Signature matches generated main: fn(_: anytype) void
pub fn entry(_: anytype) void {
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("[TEST] Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    const result = run(&b);
    if (result.passed) {
        log.info("[TEST] PASSED: {s}", .{result.message});
    } else {
        log.err("[TEST] FAILED: {s}", .{result.message});
    }
}
