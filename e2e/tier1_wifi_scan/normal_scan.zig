//! Test Scenario 1: Normal WiFi Scan Flow
//!
//! Tests the basic event-stream scan flow:
//! 1. Start scan with show_hidden=true
//! 2. Receive scan_result events (streamed AP info)
//! 3. Accumulate APs in application buffer
//! 4. Receive scan_done event
//! 5. Display and verify results

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const common = @import("common.zig");
const ApList = common.ApList;
const TestResult = common.TestResult;

/// Run the normal scan test
/// Returns TestResult indicating pass/fail
pub fn run(b: *Board) TestResult {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("TEST 1: Normal WiFi Scan Flow", .{});
    log.info("========================================", .{});
    log.info("Description: Basic scan with hidden SSID detection", .{});
    log.info("Expected: scan_result events -> scan_done (success=true)", .{});
    log.info("", .{});

    var ap_list = ApList{};

    // Perform scan
    const ap_count = common.performScan(b, &ap_list, true);
    if (ap_count < 0) {
        return TestResult.fail("Scan failed to complete");
    }

    // Log results
    common.logApList(ap_list.slice());

    // Verify results
    if (ap_count == 0) {
        log.warn("[TEST] No APs found - this may be normal in your environment", .{});
        log.warn("[TEST] Test considered PASSED (no APs is valid result)", .{});
    } else {
        log.info("[TEST] Scan found {} AP(s)", .{ap_count});

        // Verify at least one AP has valid data
        var has_valid_data = false;
        for (ap_list.slice()) |ap| {
            if (ap.channel >= 1 and ap.channel <= 14 and
                ap.rssi >= -100 and ap.rssi <= -10)
            {
                has_valid_data = true;
                break;
            }
        }

        if (!has_valid_data) {
            return TestResult.fail("AP data appears invalid (bad channel or RSSI)");
        }
    }

    // Verify event-stream model was used (scan_result events were received)
    // Note: common.performScan already validates this by collecting events

    return TestResult.pass("Normal scan flow completed successfully");
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
