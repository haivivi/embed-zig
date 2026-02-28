//! Test Scenario 4: Event Order Verification
//!
//! Strictly verifies the event delivery order:
//! scan_result(AP_1) → scan_result(AP_2) → ... → scan_result(AP_N) → scan_done
//!
//! This test:
//! 1. Tracks event sequence numbers
//! 2. Verifies no scan_result after scan_done
//! 3. Verifies scan_done is the final event
//! 4. Logs timing information between events

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const common = @import("common.zig");
const ApList = common.ApList;
const TestResult = common.TestResult;
const MAX_APS = common.MAX_APS;
const SCAN_TIMEOUT_MS = common.SCAN_TIMEOUT_MS;

/// Event tracking structure
const EventTracker = struct {
    scan_result_count: usize = 0,
    scan_done_received: bool = false,
    events_after_done: usize = 0,
    first_event_time: u64 = 0,
    last_event_time: u64 = 0,

    pub fn recordScanResult(self: *EventTracker) void {
        if (self.scan_done_received) {
            self.events_after_done += 1;
            log.err("[TEST] VIOLATION: scan_result received after scan_done!", .{});
        } else {
            self.scan_result_count += 1;
            if (self.scan_result_count == 1) {
                self.first_event_time = Board.time.nowMs();
            }
            self.last_event_time = Board.time.nowMs();
        }
    }

    pub fn recordScanDone(self: *EventTracker) void {
        if (!self.scan_done_received) {
            self.scan_done_received = true;
            self.last_event_time = Board.time.nowMs();
        }
    }
};

/// Run the event order test
/// Returns TestResult indicating pass/fail
pub fn run(b: *Board) TestResult {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("TEST 4: Event Order Verification", .{});
    log.info("========================================", .{});
    log.info("Description: Verify strict event delivery order", .{});
    log.info("Expected: scan_result × N → scan_done (no events after)", .{});
    log.info("", .{});

    var tracker = EventTracker{};
    var ap_list = ApList{};

    // Start scan
    b.wifi.scanStart(.{ .show_hidden = true }) catch {
        return TestResult.fail("Failed to start scan");
    };

    log.info("[TEST] Scan started, monitoring event order...", .{});

    const start_time = Board.time.nowMs();
    var timeout_reached = false;

    // Event monitoring loop
    while (!tracker.scan_done_received) {
        // Check timeout
        if (Board.time.nowMs() - start_time > SCAN_TIMEOUT_MS) {
            timeout_reached = true;
            break;
        }

        // Poll events
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .scan_result => |ap| {
                        tracker.recordScanResult();
                        _ = ap_list.add(ap);

                        // Log first few APs with timing
                        if (tracker.scan_result_count <= 5) {
                            const elapsed = Board.time.nowMs() - start_time;
                            log.debug("[TEST] [#{}] +{s} ({}ms)", .{
                                tracker.scan_result_count,
                                if (ap.getSsid().len == 0) "(hidden)" else ap.getSsid(),
                                elapsed,
                            });
                        } else if (tracker.scan_result_count == 6) {
                            log.debug("[TEST] ... (suppressing further AP logs)", .{});
                        }
                    },
                    .scan_done => |info| {
                        tracker.recordScanDone();
                        const elapsed = Board.time.nowMs() - start_time;

                        if (info.success) {
                            log.info("[TEST] scan_done received (success=true, {}ms)", .{elapsed});
                        } else {
                            log.err("[TEST] scan_done received (success=false, {}ms)", .{elapsed});
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

    if (timeout_reached) {
        return TestResult.fail("Timeout waiting for scan_done");
    }

    // Continue polling for a short time to verify no events after scan_done
    log.info("[TEST] Verifying no events after scan_done...", .{});
    const verify_start = Board.time.nowMs();
    while (Board.time.nowMs() - verify_start < 500) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .scan_result => {
                        tracker.recordScanResult();
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
    log.info("----- Event Order Report -----", .{});
    log.info("scan_result events: {}", .{tracker.scan_result_count});
    log.info("scan_done received: {}", .{tracker.scan_done_received});
    log.info("Events after scan_done: {}", .{tracker.events_after_done});

    if (tracker.scan_result_count > 0) {
        const duration = tracker.last_event_time - tracker.first_event_time;
        log.info("Event stream duration: {} ms", .{duration});
    }

    // Validate results
    if (tracker.events_after_done > 0) {
        return TestResult.fail("Events received after scan_done - protocol violation!");
    }

    if (!tracker.scan_done_received) {
        return TestResult.fail("scan_done never received");
    }

    // Verify event count matches AP list
    if (tracker.scan_result_count != ap_list.count) {
        log.warn("[TEST] Event count mismatch: {} events, {} in list", .{
            tracker.scan_result_count, ap_list.count,
        });
    }

    return TestResult.pass("Event order verified: scan_result × N → scan_done");
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
