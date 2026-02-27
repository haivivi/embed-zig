//! WiFi Scan Test Application (Event-Stream Model)
//!
//! Tests the WiFi scanning functionality with pure event-stream model:
//! - scanStart() - Non-blocking scan initiation
//! - scan_result events - Streamed AP info via board.nextEvent()
//! - scan_done event - Scan completion signal (without count)
//!
//! This test validates the refactored scan interface where results are
//! delivered as a stream of events rather than pulled via scanGetResults().

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const wifi_hal = @import("hal").wifi;
const ScanConfig = wifi_hal.ScanConfig;
const ApInfo = wifi_hal.ApInfo;
const AuthMode = wifi_hal.AuthMode;

fn authModeToString(mode: AuthMode) []const u8 {
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

fn formatMac(mac: [6]u8) [17]u8 {
    var buf: [17]u8 = undefined;
    _ = std.fmt.bufPrint(&buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{
        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5],
    }) catch {
        return "??:??:??:??:??:??".*;
    };
    return buf;
}

// Application-side AP list buffer (event-stream model)
// HAL/Driver no longer holds results; app decides storage policy
const MAX_APS = 64;
var ap_list: [MAX_APS]ApInfo = undefined;
var ap_count: usize = 0;

const ScanState = enum {
    init,
    starting_scan,
    scanning,
    scan_complete, // scan_done received, ready to display
    wait_interval,
};

pub fn run(_: anytype) void {
    log.info("[SCAN] ==========================================", .{});
    log.info("[SCAN]       WiFi Scan Test (Event-Stream)", .{});
    log.info("[SCAN] ==========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("[SCAN] Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("[SCAN] Board initialized", .{});
    log.info("[SCAN] Using event-stream model: scan_result → ... → scan_done", .{});

    var state: ScanState = .init;
    var scan_count: u32 = 0;
    var last_scan_time: u64 = 0;
    const SCAN_INTERVAL_MS: u64 = 5_000;

    while (Board.isRunning()) {
        const now = Board.time.nowMs();

        // Event loop: receive scan results as stream
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .scan_result => |ap| {
                        // Streamed AP info - accumulate in app buffer
                        if (ap_count < MAX_APS) {
                            ap_list[ap_count] = ap;
                            ap_count += 1;
                        }
                        // Log each AP as it arrives (demonstrates streaming)
                        const ssid = ap.getSsid();
                        const ssid_display = if (ssid.len == 0) "(hidden)" else ssid;
                        log.debug("[SCAN] + {s} (ch={}, rssi={}dBm)", .{
                            ssid_display, ap.channel, ap.rssi,
                        });
                    },
                    .scan_done => |info| {
                        // Scan completed - all scan_result events have been sent
                        if (info.success) {
                            log.info("[SCAN] Scan done signal received (success=true)", .{});
                            state = .scan_complete;
                        } else {
                            log.err("[SCAN] Scan failed (success=false)", .{});
                            // Reset for next scan even on failure
                            ap_count = 0;
                            state = .wait_interval;
                            last_scan_time = now;
                        }
                    },
                    else => {},
                },
                else => {},
            }
        }

        switch (state) {
            .init => {
                log.info("[SCAN] Starting first scan...", .{});
                state = .starting_scan;
            },
            .starting_scan => {
                scan_count += 1;
                log.info("[SCAN] ========== Scan #{} ==========", .{scan_count});

                // Reset AP list for new scan
                ap_count = 0;

                b.wifi.scanStart(.{ .show_hidden = true }) catch |err| {
                    log.err("[SCAN] Failed to start scan: {}", .{err});
                    state = .wait_interval;
                    last_scan_time = now;
                    continue;
                };
                log.info("[SCAN] Scan started, waiting for results...", .{});
                state = .scanning;
            },
            .scanning => {
                // Waiting for scan_result events and final scan_done
                // Event loop above handles the accumulation
            },
            .scan_complete => {
                // Display accumulated results
                if (ap_count == 0) {
                    log.info("[SCAN] No APs found", .{});
                } else {
                    log.info("[SCAN] Found {} APs:", .{ap_count});
                    for (ap_list[0..ap_count]) |ap| {
                        const ssid = ap.getSsid();
                        const ssid_display = if (ssid.len == 0) "(hidden)" else ssid;
                        const mac_str = formatMac(ap.bssid);
                        log.info("[SCAN]   {s:<32} {s} ch={:>2} rssi={:>3} {s}", .{
                            ssid_display, mac_str, ap.channel, ap.rssi, authModeToString(ap.auth_mode),
                        });
                    }
                    log.info("[SCAN] Total: {} APs", .{ap_count});
                }

                // Reset for next scan cycle
                ap_count = 0;
                last_scan_time = now;
                state = .wait_interval;
            },
            .wait_interval => {
                if (now - last_scan_time >= SCAN_INTERVAL_MS) {
                    state = .starting_scan;
                }
            },
        }

        Board.time.sleepMs(10);
    }
}
