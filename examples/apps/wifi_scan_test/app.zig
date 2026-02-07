//! WiFi Scan Test Application
//!
//! Tests the WiFi scanning functionality:
//! - scanStart() - Non-blocking scan initiation
//! - scan_done event via board.nextEvent()
//! - scanGetResults() - Get list of discovered APs
//!
//! Repeats scan every 10 seconds, printing all discovered APs.

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

// WiFi types
const wifi_hal = @import("hal").wifi;
const ScanConfig = wifi_hal.ScanConfig;
const ApInfo = wifi_hal.ApInfo;
const AuthMode = wifi_hal.AuthMode;

// Memory monitoring
const esp = @import("esp");
const heap = esp.idf.heap;

// ============================================================================
// Helper Functions
// ============================================================================

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

fn printMemoryStats(scan_num: u32) void {
    const internal = heap.getInternalStats();
    const psram = heap.getPsramStats();

    log.info("[MEM] === Scan #{} Memory Report ===", .{scan_num});
    log.info("[MEM] Internal: {}KB free / {}KB total (min: {}KB, largest: {}KB)", .{
        internal.free / 1024,
        internal.total / 1024,
        internal.min_free / 1024,
        internal.largest_block / 1024,
    });
    log.info("[MEM] PSRAM:    {}KB free / {}KB total (min: {}KB)", .{
        psram.free / 1024,
        psram.total / 1024,
        psram.min_free / 1024,
    });

    // Stack stats for current task (128KB PSRAM task)
    const stack = heap.getTaskStackStats(null, 128 * 1024);
    log.info("[MEM] Stack:    {} bytes used / {} total (high water: {})", .{
        stack.used,
        stack.total,
        stack.high_water,
    });
}

// ============================================================================
// Scan State Machine
// ============================================================================

const ScanState = enum {
    init,
    starting_scan,
    scanning,
    processing_results,
    wait_interval,
};

// ============================================================================
// Main Entry
// ============================================================================

pub fn run(_: anytype) void {
    log.info("", .{});
    log.info("[SCAN] ==========================================", .{});
    log.info("[SCAN]       WiFi Scan Test", .{});
    log.info("[SCAN] ==========================================", .{});
    log.info("[SCAN]", .{});
    log.info("[SCAN] Testing WiFi scanning functionality:", .{});
    log.info("[SCAN]   - scanStart()", .{});
    log.info("[SCAN]   - scan_done event", .{});
    log.info("[SCAN]   - scanGetResults()", .{});
    log.info("[SCAN]", .{});

    // Initialize board
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
    const SCAN_INTERVAL_MS: u64 = 5_000; // 5 seconds for memory monitoring

    // Event loop
    while (Board.isRunning()) {
        const now = Board.time.getTimeMs();

        // Process all pending events
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .scan_done => |info| {
                            if (info.success) {
                                log.info("[SCAN] Scan complete: {} APs found", .{info.count});
                                state = .processing_results;
                            } else {
                                log.err("[SCAN] Scan failed", .{});
                                state = .wait_interval;
                            }
                        },
                        .connected => {
                            log.info("[WIFI] Connected (unexpected in scan-only mode)", .{});
                        },
                        .disconnected => |reason| {
                            log.info("[WIFI] Disconnected: {}", .{reason});
                        },
                        .connection_failed => |reason| {
                            log.info("[WIFI] Connection failed: {}", .{reason});
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        // State machine
        switch (state) {
            .init => {
                log.info("[SCAN] Starting first scan...", .{});
                state = .starting_scan;
            },

            .starting_scan => {
                scan_count += 1;
                log.info("[SCAN]", .{});
                log.info("[SCAN] ========== Scan #{} ==========", .{scan_count});

                // Start scan with default config (all channels, active scan)
                const config = ScanConfig{
                    .show_hidden = true,
                };

                b.wifi.scanStart(config) catch |err| {
                    log.err("[SCAN] Failed to start scan: {}", .{err});
                    state = .wait_interval;
                    last_scan_time = now;
                    continue;
                };

                log.info("[SCAN] Scan started, waiting for results...", .{});
                state = .scanning;
            },

            .scanning => {
                // Waiting for scan_done event
            },

            .processing_results => {
                // Get scan results
                const results = b.wifi.scanGetResults();

                if (results.len == 0) {
                    log.info("[SCAN] No APs found", .{});
                } else {
                    log.info("[SCAN]", .{});
                    log.info("[SCAN] {s:<32} {s:<17} {s:>4} {s:>5} {s:<10}", .{
                        "SSID", "BSSID", "CH", "RSSI", "AUTH",
                    });
                    log.info("[SCAN] {s:-<32} {s:-<17} {s:->4} {s:->5} {s:-<10}", .{
                        "", "", "", "", "",
                    });

                    for (results) |ap| {
                        const ssid = ap.getSsid();
                        const ssid_display = if (ssid.len == 0) "(hidden)" else ssid;
                        const mac_str = formatMac(ap.bssid);
                        const auth_str = authModeToString(ap.auth_mode);

                        log.info("[SCAN] {s:<32} {s} {d:>4} {d:>5} {s:<10}", .{
                            ssid_display,
                            mac_str,
                            ap.channel,
                            ap.rssi,
                            auth_str,
                        });
                    }

                    log.info("[SCAN]", .{});
                    log.info("[SCAN] Total: {} APs", .{results.len});
                }

                // Print memory stats after each scan
                printMemoryStats(scan_count);

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
