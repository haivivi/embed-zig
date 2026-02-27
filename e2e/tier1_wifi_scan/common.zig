//! WiFi Scan Test - Common utilities and shared types
//!
//! This module provides shared types, constants, and helper functions
//! used by all test scenarios in the WiFi scan event-stream test suite.

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const wifi_hal = @import("hal").wifi;
const ApInfo = wifi_hal.ApInfo;
const AuthMode = wifi_hal.AuthMode;

// ============================================================================
// Shared Constants
// ============================================================================

/// Maximum number of APs to store in the application buffer
pub const MAX_APS = 64;

/// Default scan interval between consecutive scans (ms)
pub const SCAN_INTERVAL_MS: u64 = 5_000;

/// Timeout for a single scan operation (ms)
pub const SCAN_TIMEOUT_MS: u64 = 30_000;

// ============================================================================
// Shared Types
// ============================================================================

/// Application-side AP list buffer for event-stream model
/// HAL/Driver no longer holds results; app decides storage policy
pub const ApList = struct {
    aps: [MAX_APS]ApInfo = undefined,
    count: usize = 0,

    /// Reset the list for a new scan
    pub fn reset(self: *ApList) void {
        self.count = 0;
    }

    /// Add an AP to the list (returns false if buffer full)
    pub fn add(self: *ApList, ap: ApInfo) bool {
        if (self.count >= MAX_APS) {
            return false;
        }
        self.aps[self.count] = ap;
        self.count += 1;
        return true;
    }

    /// Get the current list as a slice
    pub fn slice(self: *const ApList) []const ApInfo {
        return self.aps[0..self.count];
    }
};

/// Test result tracking
pub const TestResult = struct {
    passed: bool = false,
    message: []const u8 = "",

    pub fn pass(msg: []const u8) TestResult {
        return .{ .passed = true, .message = msg };
    }

    pub fn fail(msg: []const u8) TestResult {
        return .{ .passed = false, .message = msg };
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert AuthMode to display string
pub fn authModeToString(mode: AuthMode) []const u8 {
    return switch (mode) {
        .open => "OPEN",
        .wep => "WEP",
        .wpa_psk => "WPA",
        .wpa2_psk => "WPA2",
        .wpa_wpa2_psk => "WPA/WPA2",
        .wpa3_psk => "WPA3",
        .wpa2_wpa3_psk => "WPA2/WPA3",
        .wpa2_enterprise => "WPA2-ENT",
        .wpa3_enterprise => "WPA3-ENT",
    };
}

/// Format MAC address as XX:XX:XX:XX:XX:XX
pub fn formatMac(mac: [6]u8) [17]u8 {
    var buf: [17]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    }) catch {
        return "??:??:??:??:??:??".*;
    };
    return buf;
}

/// Log a single AP info
pub fn logApInfo(ap: ApInfo, prefix: []const u8) void {
    const ssid = ap.getSsid();
    const ssid_display = if (ssid.len == 0) "(hidden)" else ssid;
    const mac_str = formatMac(ap.bssid);
    log.info("{s}{s:<32} {s} ch={:>2} rssi={:>3} {s}", .{
        prefix, ssid_display, mac_str, ap.channel, ap.rssi, authModeToString(ap.auth_mode),
    });
}

/// Log a list of APs
pub fn logApList(aps: []const ApInfo) void {
    if (aps.len == 0) {
        log.info("[TEST] No APs found", .{});
    } else {
        log.info("[TEST] Found {} APs:", .{aps.len});
        for (aps) |ap| {
            logApInfo(ap, "[TEST]   ");
        }
        log.info("[TEST] Total: {} APs", .{aps.len});
    }
}

/// Wait for scan to complete with timeout
/// Returns true if scan_done received, false on timeout
pub fn waitForScanDone(b: *Board, ap_list: *ApList, timeout_ms: u64) bool {
    const start_time = Board.time.nowMs();

    while (Board.time.nowMs() - start_time < timeout_ms) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .scan_result => |ap| {
                        _ = ap_list.add(ap);
                    },
                    .scan_done => |info| {
                        if (info.success) {
                            return true;
                        } else {
                            log.err("[TEST] Scan failed (success=false)", .{});
                            return false;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }
        Board.time.sleepMs(10);
    }

    log.err("[TEST] Scan timeout after {} ms", .{timeout_ms});
    return false;
}

/// Start a scan and wait for completion
/// Returns the number of APs found, or -1 on error
pub fn performScan(b: *Board, ap_list: *ApList, show_hidden: bool) i32 {
    ap_list.reset();

    b.wifi.scanStart(.{ .show_hidden = show_hidden }) catch |err| {
        log.err("[TEST] Failed to start scan: {}", .{err});
        return -1;
    };

    log.info("[TEST] Scan started, waiting for results...", .{});

    if (!waitForScanDone(b, ap_list, SCAN_TIMEOUT_MS)) {
        return -1;
    }

    return @intCast(ap_list.count);
}
