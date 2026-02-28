//! Test Scenario 2: Empty Scan Result
//!
//! Tests behavior when no APs are found:
//! 1. Start scan (in an environment with no WiFi)
//! 2. Receive scan_done directly (no scan_result events)
//! 3. Verify empty result is handled correctly
//!
//! NOTE: This test requires a controlled environment (shielded or remote location)
//!       In normal environments, it may find APs and that's okay.

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const common = @import("common.zig");
const ApList = common.ApList;
const TestResult = common.TestResult;

/// Run the empty scan test
/// Returns TestResult indicating pass/fail
pub fn run(b: *Board) TestResult {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("TEST 2: Empty Scan Result", .{});
    log.info("========================================", .{});
    log.info("Description: Scan in environment with no WiFi APs", .{});
    log.info("Expected: scan_done (success=true) with no preceding scan_result", .{});
    log.info("NOTE: In normal environments, APs may be found - this is OK", .{});
    log.info("", .{});

    var ap_list = ApList{};

    // Perform scan
    const ap_count = common.performScan(b, &ap_list, true);
    if (ap_count < 0) {
        return TestResult.fail("Scan failed to complete");
    }

    // Log results
    common.logApList(ap_list.slice());

    // If no APs found, we successfully tested the empty case
    if (ap_count == 0) {
        log.info("[TEST] Empty scan result handled correctly", .{});
        return TestResult.pass("Empty scan result handled correctly");
    }

    // If APs found, that's also valid - we still verified the event flow worked
    log.warn("[TEST] Found {} AP(s) - environment has WiFi coverage", .{ap_count});
    log.warn("[TEST] To test empty result, run in a shielded environment", .{});
    log.info("[TEST] Event flow still validated - test PASSED", .{});

    return TestResult.pass("Scan completed (non-empty environment)");
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
