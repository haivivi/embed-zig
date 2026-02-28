//! WiFi Scan Test Suite - Event-Stream Model
//!
//! This is the main entry point for the WiFi scan E2E test suite.
//! It runs multiple test scenarios to validate the refactored scan interface.
//!
//! Test Scenarios:
//! 1. Normal Scan Flow - Basic scan with hidden SSID detection
//! 2. Empty Scan Result - Handling when no APs are found
//! 3. Multiple Scan Cycles - Consecutive scans with buffer reset
//! 4. Event Order Verification - Strict event delivery order validation
//! 5. Buffer Boundary - Overflow handling when >64 APs found
//!
//! Usage:
//!   Run all tests:   bazel run //e2e/tier1_wifi_scan:<target>
//!   Select test:     Set TEST_MODE in build config or modify main() below

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// Test modules
const normal_scan = @import("normal_scan.zig");
const empty_scan = @import("empty_scan.zig");
const multi_cycle = @import("multi_cycle.zig");
const event_order = @import("event_order.zig");
const buffer_boundary = @import("buffer_boundary.zig");
const common = @import("common.zig");

/// Test mode selection
const TestMode = enum {
    all, // Run all tests sequentially
    normal, // Test 1: Normal scan flow
    empty, // Test 2: Empty result handling
    multi_cycle, // Test 3: Multiple scan cycles
    event_order, // Test 4: Event order verification
    buffer, // Test 5: Buffer boundary
    continuous, // Run continuously (demo mode)
};

/// Current test mode (modify here or via build config)
const CURRENT_MODE: TestMode = .all;

/// Test statistics
const TestStats = struct {
    total: u32 = 0,
    passed: u32 = 0,
    failed: u32 = 0,

    pub fn record(self: *TestStats, result: common.TestResult) void {
        self.total += 1;
        if (result.passed) {
            self.passed += 1;
            log.info("[SUITE] ✓ PASSED: {s}", .{result.message});
        } else {
            self.failed += 1;
            log.err("[SUITE] ✗ FAILED: {s}", .{result.message});
        }
    }

    pub fn printSummary(self: *const TestStats) void {
        log.info("", .{});
        log.info("========================================", .{});
        log.info("Test Suite Summary", .{});
        log.info("========================================", .{});
        log.info("Total:  {}", .{self.total});
        log.info("Passed: {}", .{self.passed});
        log.info("Failed: {}", .{self.failed});

        if (self.failed == 0) {
            log.info("", .{});
            log.info("🎉 All tests PASSED!", .{});
        } else {
            log.err("", .{});
            log.err("⚠️  {} test(s) FAILED", .{self.failed});
        }
    }
};

/// Run a single test with error handling
fn runTest(b: *Board, name: []const u8, test_fn: fn (*Board) common.TestResult) common.TestResult {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("Running: {s}", .{name});
    log.info("========================================", .{});

    return test_fn(b);
}

/// Run all tests sequentially
fn runAllTests(b: *Board) TestStats {
    var stats = TestStats{};

    stats.record(runTest(b, "Normal Scan Flow", normal_scan.run));
    stats.record(runTest(b, "Empty Scan Result", empty_scan.run));
    stats.record(runTest(b, "Multiple Scan Cycles", multi_cycle.run));
    stats.record(runTest(b, "Event Order Verification", event_order.run));
    stats.record(runTest(b, "Buffer Boundary", buffer_boundary.run));

    return stats;
}

/// Run a specific test mode
fn runTestMode(b: *Board, mode: TestMode) void {
    var stats = TestStats{};

    switch (mode) {
        .all => {
            stats = runAllTests(b);
        },
        .normal => {
            stats.record(normal_scan.run(b));
        },
        .empty => {
            stats.record(empty_scan.run(b));
        },
        .multi_cycle => {
            stats.record(multi_cycle.run(b));
        },
        .event_order => {
            stats.record(event_order.run(b));
        },
        .buffer => {
            stats.record(buffer_boundary.run(b));
        },
        .continuous => {
            runContinuousMode(b);
            return;
        },
    }

    stats.printSummary();
}

/// Continuous demo mode (runs scans indefinitely)
fn runContinuousMode(b: *Board) void {
    log.info("", .{});
    log.info("========================================", .{});
    log.info("Continuous Demo Mode", .{});
    log.info("========================================", .{});
    log.info("Running scans continuously (Ctrl+C to stop)", .{});

    var scan_count: u32 = 0;

    while (Board.isRunning()) {
        scan_count += 1;
        log.info("", .{});
        log.info("----- Scan #{} -----", .{scan_count});

        var ap_list = common.ApList{};
        const result = common.performScan(b, &ap_list, true);

        if (result >= 0) {
            common.logApList(ap_list.slice());
            log.info("Waiting 5 seconds before next scan...", .{});
            Board.time.sleepMs(5000);
        } else {
            log.err("Scan failed, retrying in 5 seconds...", .{});
            Board.time.sleepMs(5000);
        }
    }
}

/// Main entry point
pub fn run(_: anytype) void {
    // Print banner
    log.info("", .{});
    log.info("╔════════════════════════════════════════════════════════════╗", .{});
    log.info("║     WiFi Scan Test Suite - Event-Stream Model              ║", .{});
    log.info("╚════════════════════════════════════════════════════════════╝", .{});
    log.info("", .{});
    log.info("Tests the refactored WiFi scan interface:", .{});
    log.info("  - Results delivered as scan_result event stream", .{});
    log.info("  - scan_done signals completion (no count field)", .{});
    log.info("  - Application manages AP list storage", .{});
    log.info("", .{});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("[SUITE] Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("[SUITE] Board initialized successfully", .{});
    log.info("[SUITE] Test mode: {s}", .{@tagName(CURRENT_MODE)});

    // Run selected test mode
    runTestMode(&b, CURRENT_MODE);

    log.info("", .{});
    log.info("[SUITE] Test suite completed", .{});
}
