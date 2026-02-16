//! WiFi Scan Test Application
//!
//! Tests the WiFi scanning functionality:
//! - scanStart() - Non-blocking scan initiation
//! - scan_done event via board.nextEvent()
//! - scanGetResults() - Get list of discovered APs

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

const ScanState = enum { init, starting_scan, scanning, processing_results, wait_interval };

pub fn run(_: anytype) void {
    log.info("[SCAN] ==========================================", .{});
    log.info("[SCAN]       WiFi Scan Test", .{});
    log.info("[SCAN] ==========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("[SCAN] Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("[SCAN] Board initialized", .{});

    var state: ScanState = .init;
    var scan_count: u32 = 0;
    var last_scan_time: u64 = 0;
    const SCAN_INTERVAL_MS: u64 = 5_000;

    while (Board.isRunning()) {
        const now = Board.time.nowMs();

        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| switch (wifi_event) {
                    .scan_done => |info| {
                        if (info.success) {
                            log.info("[SCAN] Scan complete: {} APs found", .{info.count});
                            state = .processing_results;
                        } else {
                            log.err("[SCAN] Scan failed", .{});
                            state = .wait_interval;
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

                b.wifi.scanStart(.{ .show_hidden = true }) catch |err| {
                    log.err("[SCAN] Failed to start scan: {}", .{err});
                    state = .wait_interval;
                    last_scan_time = now;
                    continue;
                };
                log.info("[SCAN] Scan started...", .{});
                state = .scanning;
            },
            .scanning => {},
            .processing_results => {
                const results = b.wifi.scanGetResults();
                if (results.len == 0) {
                    log.info("[SCAN] No APs found", .{});
                } else {
                    for (results) |ap| {
                        const ssid = ap.getSsid();
                        const ssid_display = if (ssid.len == 0) "(hidden)" else ssid;
                        const mac_str = formatMac(ap.bssid);
                        log.info("[SCAN] {s:<32} {s} ch={} rssi={} {s}", .{
                            ssid_display, mac_str, ap.channel, ap.rssi, authModeToString(ap.auth_mode),
                        });
                    }
                    log.info("[SCAN] Total: {} APs", .{results.len});
                }
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
