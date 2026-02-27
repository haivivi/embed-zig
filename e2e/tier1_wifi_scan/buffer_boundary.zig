//! Test Scenario 5: Buffer Boundary
//!
//! Tests behavior when more APs are found than the application buffer can hold.
//! The application buffer (MAX_APS = 64) should handle overflow gracefully.
//!
//! This test:
//! 1. Performs scan in a dense WiFi environment
//! 2. Tracks if buffer overflow occurs
//! 3. Verifies no crash or corruption
//! 4. Logs how many APs were dropped

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const common = @import("common.zig");
const ApList = common.ApList;
const TestResult = common.TestResult;
const MAX_APS = common.MAX_APS;
const SCAN_TIMEOUT_MS = common.SCAN_TIMEOUT_MS;

/// Run the buffer boundary test
/// Returns TestResult indicating pass/fail
pub fn run(b: *Board) TestResult {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("TEST 5: Buffer Boundary", .{});
    log.info("========================================", .{});
    log.info("Description: Test AP buffer overflow handling", .{});
    log.info("Buffer size: {} APs", .{MAX_APS});
    log.info("Expected: Graceful handling when > {} APs found", .{MAX_APS});
    log.info("", .{});

    var total_events: usize = 0;
    var dropped_events: usize = 0;
    var ap_list = ApList{};

    // Start scan
    b.wifi.scanStart(.{ .show_hidden = true }) catch {
        return TestResult.fail("Failed to start scan");
    };

    log.info("[TEST] Scan started...", .{});

    const start_time = Board.time.nowMs();
    var scan_done = false;

    // Event collection loop
    while (!scan_done) {
        // Check timeout
        if (Board.time.nowMs() - start_time > SCAN_TIMEOUT_MS) {
            return TestResult.fail("Timeout waiting for scan completion");
        }

        // Poll events
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .scan_result => |ap| {
                        total_events += 1;

                        // Try to add to buffer
                        const added = ap_list.add(ap);
                        if (!added) {
                            dropped_events += 1;

                            // Log only first few drops
                            if (dropped_events <= 3) {
                                log.warn("[TEST] Buffer full, dropped AP: {s}", .{
                                    if (ap.getSsid().len == 0) "(hidden)" else ap.getSsid(),
                                });
                            } else if (dropped_events == 4) {
                                log.warn("[TEST] ... (suppressing further drop logs)", .{});
                            }
                        }
                    },
                    .scan_done => |info| {
                        scan_done = true;
                        if (info.success) {
                            log.info("[TEST] Scan completed successfully", .{});
                        } else {
                            log.err("[TEST] Scan failed", .{});
                            return TestResult.fail("Scan reported failure");
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        Board.time.sleepMs(10);
    }

    // Generate report
    log.info("", .{});
    log.info("----- Buffer Boundary Report -----", .{});
    log.info("Total scan_result events: {}", .{total_events});
    log.info("Buffer capacity: {}", .{MAX_APS});
    log.info("Stored in buffer: {}", .{ap_list.count});
    log.info("Dropped (overflow): {}", .{dropped_events});

    if (dropped_events > 0) {
        log.warn("[TEST] Buffer overflow occurred - {} APs dropped", .{dropped_events});
        log.info("[TEST] This is expected behavior in dense WiFi environments", .{});
    } else {
        log.info("[TEST] No overflow - all {} APs fit in buffer", .{total_events});
    }

    // Verify buffer integrity
    if (ap_list.count > MAX_APS) {
        return TestResult.fail("Buffer corruption: count exceeds MAX_APS");
    }

    // Verify we can safely iterate the buffer
    var valid_count: usize = 0;
    for (ap_list.slice()) |ap| {
        // Basic validation
        if (ap.channel >= 1 and ap.channel <= 14) {
            valid_count += 1;
        }
    }

    if (valid_count != ap_list.count) {
        log.warn("[TEST] Some APs have invalid data (channel out of range)", .{});
    }

    if (dropped_events > 0) {
        return TestResult.pass("Buffer overflow handled gracefully");
    } else {
        return TestResult.pass("Buffer capacity sufficient for environment");
    }
}

/// Run with assertion check for CI/CD
pub fn runWithAssertions(b: *Board) !void {
    const result = run(b);
    if (!result.passed) {
        log.err("[TEST] FAILED: {s}", .{result.message});
        return error.TestFailed;
    }
    log.info("[TEST] PASSED: {s}", .{result.message});
}
