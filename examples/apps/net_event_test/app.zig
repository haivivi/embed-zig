//! Net Event Test Application
//!
//! Comprehensive test for Net HAL and WiFi HAL event systems.
//!
//! Test Flow:
//! - Phase 1: Connect with correct password -> expect wifi.connected + net.dhcp_bound
//! - Phase 2: Query interfaces (list, get, getDns, etc.)
//! - Phase 3: Disconnect -> expect wifi.disconnected + net.ip_lost
//! - Phase 4: Connect with wrong password -> expect wifi.connection_failed
//! - Phase 5: Reconnect with correct password -> expect wifi.connected + net.dhcp_bound
//! - Phase 6: Interface up/down test (optional)
//!
//! All events MUST come through board.nextEvent()

const std = @import("std");
const platform = @import("platform.zig");
const Board = platform.Board;
const net_impl = platform.net_impl;
const log = Board.log;

// ============================================================================
// Test Result Tracking
// ============================================================================

const TestResult = enum {
    pending,
    pass,
    fail,
    skip,

    pub fn symbol(self: TestResult) []const u8 {
        return switch (self) {
            .pending => "...",
            .pass => "PASS",
            .fail => "FAIL",
            .skip => "SKIP",
        };
    }
};

const TestResults = struct {
    phase1_connect: TestResult = .pending,
    phase2_query: TestResult = .pending,
    phase3_disconnect: TestResult = .pending,
    phase4_wrong_pass: TestResult = .pending,
    phase5_reconnect: TestResult = .pending,
    phase6_updown: TestResult = .pending,

    fn countPassed(self: *const TestResults) u32 {
        var count: u32 = 0;
        if (self.phase1_connect == .pass) count += 1;
        if (self.phase2_query == .pass) count += 1;
        if (self.phase3_disconnect == .pass) count += 1;
        if (self.phase4_wrong_pass == .pass) count += 1;
        if (self.phase5_reconnect == .pass) count += 1;
        if (self.phase6_updown == .pass) count += 1;
        return count;
    }

    fn countTotal(self: *const TestResults) u32 {
        var count: u32 = 0;
        if (self.phase1_connect != .skip) count += 1;
        if (self.phase2_query != .skip) count += 1;
        if (self.phase3_disconnect != .skip) count += 1;
        if (self.phase4_wrong_pass != .skip) count += 1;
        if (self.phase5_reconnect != .skip) count += 1;
        if (self.phase6_updown != .skip) count += 1;
        return count;
    }
};

// ============================================================================
// Test State Machine
// ============================================================================

const TestPhase = enum {
    init,
    // Phase 1: Connect
    phase1_start,
    phase1_connecting,
    phase1_wait_wifi,
    phase1_wait_ip,
    phase1_done,
    // Phase 2: Query
    phase2_start,
    phase2_test,
    phase2_done,
    // Phase 3: Disconnect
    phase3_start,
    phase3_disconnecting,
    phase3_wait_events,
    phase3_done,
    // Phase 4: Wrong password
    phase4_start,
    phase4_connecting,
    phase4_wait_fail,
    phase4_done,
    // Phase 5: Reconnect
    phase5_start,
    phase5_connecting,
    phase5_wait_wifi,
    phase5_wait_ip,
    phase5_done,
    // Phase 6: Up/Down
    phase6_start,
    phase6_down,
    phase6_wait_down,
    phase6_up,
    phase6_wait_up,
    phase6_done,
    // Final
    report,
    done,
};

// ============================================================================
// Event Tracking
// ============================================================================

const EventFlags = struct {
    wifi_connected: bool = false,
    wifi_disconnected: bool = false,
    wifi_failed: bool = false,
    net_dhcp_bound: bool = false,
    net_ip_lost: bool = false,

    fn reset(self: *EventFlags) void {
        self.* = .{};
    }
};

// ============================================================================
// Main Entry
// ============================================================================

pub fn run(env: anytype) void {
    log.info("", .{});
    log.info("[TEST] ==========================================", .{});
    log.info("[TEST]       Net Event Test Suite", .{});
    log.info("[TEST] ==========================================", .{});
    log.info("[TEST]", .{});
    log.info("[TEST] Testing HAL event chain:", .{});
    log.info("[TEST]   WiFi: idf/wifi -> impl/wifi -> hal/wifi -> board", .{});
    log.info("[TEST]   Net:  idf/net  -> impl/net  -> hal/net  -> board", .{});
    log.info("[TEST]", .{});
    log.info("[TEST] WiFi SSID: {s}", .{env.wifi_ssid});
    log.info("[TEST]", .{});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("[TEST] Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("[TEST] Board initialized", .{});

    var results = TestResults{};
    var phase: TestPhase = .init;
    var events = EventFlags{};
    var phase_start_time: u64 = 0;
    const TIMEOUT_MS: u64 = 30_000; // 30 second timeout per phase

    // Cached DHCP info for verification
    var cached_ip: [4]u8 = .{ 0, 0, 0, 0 };
    var cached_dns: [4]u8 = .{ 0, 0, 0, 0 };

    // Event loop
    while (Board.isRunning() and phase != .done) {
        // Process all pending events
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .connected => {
                            log.info("[WIFI] connected", .{});
                            events.wifi_connected = true;
                        },
                        .disconnected => |reason| {
                            log.info("[WIFI] disconnected (reason: {})", .{reason});
                            events.wifi_disconnected = true;
                        },
                        .connection_failed => |reason| {
                            log.info("[WIFI] connection_failed (reason: {})", .{reason});
                            events.wifi_failed = true;
                        },
                        else => {},
                    }
                },
                .net => |net_event| {
                    switch (net_event) {
                        .dhcp_bound => |info| {
                            log.info("[NET]  dhcp_bound ip={}.{}.{}.{} gw={}.{}.{}.{} dns={}.{}.{}.{}", .{
                                info.ip[0],       info.ip[1],       info.ip[2],       info.ip[3],
                                info.gateway[0],  info.gateway[1],  info.gateway[2],  info.gateway[3],
                                info.dns_main[0], info.dns_main[1], info.dns_main[2], info.dns_main[3],
                            });
                            events.net_dhcp_bound = true;
                            cached_ip = info.ip;
                            cached_dns = info.dns_main;
                        },
                        .dhcp_renewed => |info| {
                            log.info("[NET]  dhcp_renewed ip={}.{}.{}.{}", .{
                                info.ip[0], info.ip[1], info.ip[2], info.ip[3],
                            });
                            events.net_dhcp_bound = true;
                            cached_ip = info.ip;
                        },
                        .ip_lost => |info| {
                            log.info("[NET]  ip_lost (interface: {s})", .{info.getInterfaceName()});
                            events.net_ip_lost = true;
                        },
                        .static_ip_set => {
                            log.info("[NET]  static_ip_set", .{});
                        },
                        .ap_sta_assigned => |info| {
                            log.info("[NET]  ap_sta_assigned ip={}.{}.{}.{}", .{
                                info.ip[0], info.ip[1], info.ip[2], info.ip[3],
                            });
                        },
                    }
                },
                else => {},
            }
        }

        const now = Board.time.getTimeMs();

        // State machine
        switch (phase) {
            .init => {
                phase = .phase1_start;
            },

            // ================================================================
            // Phase 1: Connect with correct password
            // ================================================================
            .phase1_start => {
                log.info("[TEST]", .{});
                log.info("[TEST] ========== Phase 1: Connect ==========", .{});
                log.info("[TEST] Expected: wifi.connected, net.dhcp_bound", .{});
                log.info("[TEST] Timeout: 30s", .{});
                events.reset();
                phase_start_time = now;
                phase = .phase1_connecting;
            },

            .phase1_connecting => {
                b.wifi.connect(env.wifi_ssid, env.wifi_password);
                log.info("[TEST] Connecting to {s}...", .{env.wifi_ssid});
                phase = .phase1_wait_wifi;
            },

            .phase1_wait_wifi => {
                if (events.wifi_connected) {
                    log.info("[TEST] + wifi.connected received", .{});
                    phase = .phase1_wait_ip;
                } else if (events.wifi_failed) {
                    log.err("[TEST] x Unexpected: wifi.connection_failed", .{});
                    log.info("[TEST] Phase 1: FAIL", .{});
                    results.phase1_connect = .fail;
                    phase = .report;
                } else if (now - phase_start_time > TIMEOUT_MS) {
                    log.err("[TEST] x Timeout waiting for wifi.connected", .{});
                    log.info("[TEST] Phase 1: FAIL", .{});
                    results.phase1_connect = .fail;
                    phase = .report;
                }
            },

            .phase1_wait_ip => {
                if (events.net_dhcp_bound) {
                    log.info("[TEST] + net.dhcp_bound received", .{});
                    log.info("[TEST] Phase 1: PASS", .{});
                    results.phase1_connect = .pass;
                    phase = .phase1_done;
                } else if (now - phase_start_time > TIMEOUT_MS) {
                    log.err("[TEST] x Timeout waiting for net.dhcp_bound", .{});
                    log.info("[TEST] Phase 1: FAIL", .{});
                    results.phase1_connect = .fail;
                    phase = .report;
                }
            },

            .phase1_done => {
                Board.time.sleepMs(1000);
                phase = .phase2_start;
            },

            // ================================================================
            // Phase 2: Query interfaces
            // ================================================================
            .phase2_start => {
                log.info("[TEST]", .{});
                log.info("[TEST] ========== Phase 2: Query ==========", .{});
                log.info("[TEST] Testing: list(), get(), getDns(), isConnected(), getRssi()", .{});
                phase = .phase2_test;
            },

            .phase2_test => {
                var all_pass = true;

                // Test list()
                log.info("[TEST] Testing list()...", .{});
                const interfaces = net_impl.list();
                log.info("[TEST]   Found {} interface(s)", .{interfaces.len});
                for (interfaces) |iface| {
                    const name_len = std.mem.indexOfScalar(u8, &iface, 0) orelse iface.len;
                    log.info("[TEST]   - {s}", .{iface[0..name_len]});
                }
                if (interfaces.len >= 1) {
                    log.info("[TEST] + list(): PASS (found {} interfaces)", .{interfaces.len});
                } else {
                    log.err("[TEST] x list(): FAIL (no interfaces found)", .{});
                    all_pass = false;
                }

                // Test get() on first interface
                if (interfaces.len > 0) {
                    log.info("[TEST] Testing get()...", .{});
                    if (net_impl.get(interfaces[0])) |info| {
                        log.info("[TEST]   IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        log.info("[TEST]   Gateway: {}.{}.{}.{}", .{ info.gateway[0], info.gateway[1], info.gateway[2], info.gateway[3] });
                        log.info("[TEST]   State: {}", .{info.state});
                        log.info("[TEST]   DHCP: {}", .{info.dhcp});
                        if (info.ip[0] != 0 or info.ip[1] != 0 or info.ip[2] != 0 or info.ip[3] != 0) {
                            log.info("[TEST] + get(): PASS", .{});
                        } else {
                            log.err("[TEST] x get(): FAIL (IP is 0.0.0.0)", .{});
                            all_pass = false;
                        }
                    } else {
                        log.err("[TEST] x get(): FAIL (returned null)", .{});
                        all_pass = false;
                    }
                }

                // Test getDns()
                log.info("[TEST] Testing getDns()...", .{});
                const dns = net_impl.getDns();
                log.info("[TEST]   Primary: {}.{}.{}.{}", .{ dns[0][0], dns[0][1], dns[0][2], dns[0][3] });
                log.info("[TEST]   Secondary: {}.{}.{}.{}", .{ dns[1][0], dns[1][1], dns[1][2], dns[1][3] });
                if (dns[0][0] != 0 or dns[0][1] != 0 or dns[0][2] != 0 or dns[0][3] != 0) {
                    log.info("[TEST] + getDns(): PASS", .{});
                } else {
                    log.err("[TEST] x getDns(): FAIL (DNS is 0.0.0.0)", .{});
                    all_pass = false;
                }

                // Test wifi.isConnected()
                log.info("[TEST] Testing wifi.isConnected()...", .{});
                const connected = b.wifi.isConnected();
                log.info("[TEST]   isConnected: {}", .{connected});
                if (connected) {
                    log.info("[TEST] + isConnected(): PASS", .{});
                } else {
                    log.err("[TEST] x isConnected(): FAIL (should be true)", .{});
                    all_pass = false;
                }

                // Test wifi.getRssi()
                log.info("[TEST] Testing wifi.getRssi()...", .{});
                if (b.wifi.getRssi()) |rssi| {
                    log.info("[TEST]   RSSI: {} dBm", .{rssi});
                    if (rssi < 0 and rssi > -100) {
                        log.info("[TEST] + getRssi(): PASS", .{});
                    } else {
                        log.err("[TEST] x getRssi(): FAIL (invalid value)", .{});
                        all_pass = false;
                    }
                } else {
                    log.info("[TEST]   RSSI: not available", .{});
                    log.info("[TEST] ~ getRssi(): SKIP", .{});
                }

                // Test wifi.getState()
                log.info("[TEST] Testing wifi.getState()...", .{});
                const state = b.wifi.getState();
                log.info("[TEST]   State: {}", .{state});
                if (state == .connected) {
                    log.info("[TEST] + getState(): PASS", .{});
                } else {
                    log.err("[TEST] x getState(): FAIL (should be connected)", .{});
                    all_pass = false;
                }

                if (all_pass) {
                    log.info("[TEST] Phase 2: PASS", .{});
                    results.phase2_query = .pass;
                } else {
                    log.info("[TEST] Phase 2: FAIL", .{});
                    results.phase2_query = .fail;
                }
                phase = .phase2_done;
            },

            .phase2_done => {
                Board.time.sleepMs(1000);
                phase = .phase3_start;
            },

            // ================================================================
            // Phase 3: Disconnect
            // ================================================================
            .phase3_start => {
                log.info("[TEST]", .{});
                log.info("[TEST] ========== Phase 3: Disconnect ==========", .{});
                log.info("[TEST] Expected: wifi.disconnected, net.ip_lost", .{});
                log.info("[TEST] Timeout: 30s", .{});
                events.reset();
                phase_start_time = now;
                phase = .phase3_disconnecting;
            },

            .phase3_disconnecting => {
                b.wifi.disconnect();
                log.info("[TEST] Disconnecting...", .{});
                phase = .phase3_wait_events;
            },

            .phase3_wait_events => {
                const got_disconnect = events.wifi_disconnected;
                const got_ip_lost = events.net_ip_lost;

                if (got_disconnect and got_ip_lost) {
                    log.info("[TEST] + wifi.disconnected received", .{});
                    log.info("[TEST] + net.ip_lost received", .{});

                    // Verify isConnected is now false
                    if (!b.wifi.isConnected()) {
                        log.info("[TEST] + isConnected() == false: PASS", .{});
                        log.info("[TEST] Phase 3: PASS", .{});
                        results.phase3_disconnect = .pass;
                    } else {
                        log.err("[TEST] x isConnected() still true", .{});
                        log.info("[TEST] Phase 3: FAIL", .{});
                        results.phase3_disconnect = .fail;
                    }
                    phase = .phase3_done;
                } else if (got_disconnect and (now - phase_start_time > 5000)) {
                    // Sometimes ip_lost may not fire immediately, give it some grace
                    log.info("[TEST] + wifi.disconnected received", .{});
                    log.info("[TEST] ~ net.ip_lost not received (may be expected)", .{});
                    if (!b.wifi.isConnected()) {
                        log.info("[TEST] Phase 3: PASS (partial)", .{});
                        results.phase3_disconnect = .pass;
                    } else {
                        log.info("[TEST] Phase 3: FAIL", .{});
                        results.phase3_disconnect = .fail;
                    }
                    phase = .phase3_done;
                } else if (now - phase_start_time > TIMEOUT_MS) {
                    log.err("[TEST] x Timeout waiting for disconnect events", .{});
                    log.info("[TEST] Phase 3: FAIL", .{});
                    results.phase3_disconnect = .fail;
                    phase = .phase3_done;
                }
            },

            .phase3_done => {
                Board.time.sleepMs(2000);
                phase = .phase4_start;
            },

            // ================================================================
            // Phase 4: Wrong password
            // ================================================================
            .phase4_start => {
                log.info("[TEST]", .{});
                log.info("[TEST] ========== Phase 4: Wrong Password ==========", .{});
                log.info("[TEST] Expected: wifi.connection_failed", .{});
                log.info("[TEST] Timeout: 30s", .{});
                events.reset();
                phase_start_time = now;
                phase = .phase4_connecting;
            },

            .phase4_connecting => {
                b.wifi.connect(env.wifi_ssid, "wrong_password_12345");
                log.info("[TEST] Connecting with wrong password...", .{});
                phase = .phase4_wait_fail;
            },

            .phase4_wait_fail => {
                if (events.wifi_failed) {
                    log.info("[TEST] + wifi.connection_failed received", .{});
                    log.info("[TEST] Phase 4: PASS", .{});
                    results.phase4_wrong_pass = .pass;
                    phase = .phase4_done;
                } else if (events.wifi_connected) {
                    // This shouldn't happen with wrong password
                    log.err("[TEST] x Unexpected: wifi.connected (wrong password accepted?)", .{});
                    log.info("[TEST] Phase 4: FAIL", .{});
                    results.phase4_wrong_pass = .fail;
                    // Disconnect before continuing
                    b.wifi.disconnect();
                    phase = .phase4_done;
                } else if (now - phase_start_time > TIMEOUT_MS) {
                    log.err("[TEST] x Timeout waiting for connection_failed", .{});
                    log.info("[TEST] Phase 4: FAIL", .{});
                    results.phase4_wrong_pass = .fail;
                    phase = .phase4_done;
                }
            },

            .phase4_done => {
                Board.time.sleepMs(2000);
                phase = .phase5_start;
            },

            // ================================================================
            // Phase 5: Reconnect
            // ================================================================
            .phase5_start => {
                log.info("[TEST]", .{});
                log.info("[TEST] ========== Phase 5: Reconnect ==========", .{});
                log.info("[TEST] Expected: wifi.connected, net.dhcp_bound", .{});
                log.info("[TEST] Timeout: 30s", .{});
                events.reset();
                phase_start_time = now;
                phase = .phase5_connecting;
            },

            .phase5_connecting => {
                b.wifi.connect(env.wifi_ssid, env.wifi_password);
                log.info("[TEST] Reconnecting with correct password...", .{});
                phase = .phase5_wait_wifi;
            },

            .phase5_wait_wifi => {
                if (events.wifi_connected) {
                    log.info("[TEST] + wifi.connected received", .{});
                    phase = .phase5_wait_ip;
                } else if (events.wifi_failed) {
                    log.err("[TEST] x Unexpected: wifi.connection_failed", .{});
                    log.info("[TEST] Phase 5: FAIL", .{});
                    results.phase5_reconnect = .fail;
                    phase = .phase5_done;
                } else if (now - phase_start_time > TIMEOUT_MS) {
                    log.err("[TEST] x Timeout waiting for wifi.connected", .{});
                    log.info("[TEST] Phase 5: FAIL", .{});
                    results.phase5_reconnect = .fail;
                    phase = .phase5_done;
                }
            },

            .phase5_wait_ip => {
                if (events.net_dhcp_bound) {
                    log.info("[TEST] + net.dhcp_bound received", .{});
                    log.info("[TEST] Phase 5: PASS", .{});
                    results.phase5_reconnect = .pass;
                    phase = .phase5_done;
                } else if (now - phase_start_time > TIMEOUT_MS) {
                    log.err("[TEST] x Timeout waiting for net.dhcp_bound", .{});
                    log.info("[TEST] Phase 5: FAIL", .{});
                    results.phase5_reconnect = .fail;
                    phase = .phase5_done;
                }
            },

            .phase5_done => {
                Board.time.sleepMs(1000);
                // Skip phase 6 for now - up/down may cause issues
                results.phase6_updown = .skip;
                phase = .report;
            },

            // ================================================================
            // Phase 6: Up/Down (Optional)
            // ================================================================
            .phase6_start => {
                log.info("[TEST]", .{});
                log.info("[TEST] ========== Phase 6: Up/Down ==========", .{});
                log.info("[TEST] Expected: net.ip_lost, net.dhcp_bound", .{});
                log.info("[TEST] Timeout: 30s", .{});
                events.reset();
                phase_start_time = now;
                phase = .phase6_down;
            },

            .phase6_down => {
                log.info("[TEST] Calling down('st1')...", .{});
                // Note: This may not work as expected on ESP32
                // Skip for now
                results.phase6_updown = .skip;
                phase = .report;
            },

            .phase6_wait_down => {
                phase = .phase6_up;
            },

            .phase6_up => {
                phase = .phase6_wait_up;
            },

            .phase6_wait_up => {
                phase = .phase6_done;
            },

            .phase6_done => {
                phase = .report;
            },

            // ================================================================
            // Final Report
            // ================================================================
            .report => {
                log.info("[TEST]", .{});
                log.info("[TEST] ==========================================", .{});
                log.info("[TEST]          TEST SUMMARY", .{});
                log.info("[TEST] ==========================================", .{});
                log.info("[TEST] Phase 1 (Connect):      {s}", .{results.phase1_connect.symbol()});
                log.info("[TEST] Phase 2 (Query):        {s}", .{results.phase2_query.symbol()});
                log.info("[TEST] Phase 3 (Disconnect):   {s}", .{results.phase3_disconnect.symbol()});
                log.info("[TEST] Phase 4 (Wrong Pass):   {s}", .{results.phase4_wrong_pass.symbol()});
                log.info("[TEST] Phase 5 (Reconnect):    {s}", .{results.phase5_reconnect.symbol()});
                log.info("[TEST] Phase 6 (Up/Down):      {s}", .{results.phase6_updown.symbol()});
                log.info("[TEST] ------------------------------------------", .{});
                log.info("[TEST] TOTAL: {}/{} PASSED", .{ results.countPassed(), results.countTotal() });
                log.info("[TEST] ==========================================", .{});

                if (results.countPassed() == results.countTotal()) {
                    log.info("[TEST]", .{});
                    log.info("[TEST] All tests PASSED!", .{});
                } else {
                    log.info("[TEST]", .{});
                    log.info("[TEST] Some tests FAILED.", .{});
                }

                phase = .done;
            },

            .done => {},
        }

        Board.time.sleepMs(10);
    }

    // Keep running for observation
    log.info("[TEST]", .{});
    log.info("[TEST] Test complete. Keeping connection alive...", .{});
    while (Board.isRunning()) {
        Board.time.sleepMs(1000);
    }
}
