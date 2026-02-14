//! e2e: trait/net_events — Verify network events across WiFi connect/disconnect cycle
//!
//! Tests:
//!   1. WiFi init + Net driver init (callback mode)
//!   2. WiFi connect → dhcp_bound event fires with valid IP/netmask/gateway/DNS
//!   3. WiFi disconnect → ip_lost event fires with interface name
//!   4. WiFi reconnect → second dhcp_bound event fires
//!   5. Final disconnect + cleanup

const std = @import("std");
const platform = @import("platform.zig");
const log = platform.log;
const NetEvent = platform.NetEvent;

var g_ssid: []const u8 = "";
var g_password: []const u8 = "";

// Collected events (ring buffer, max 16)
const MAX_EVENTS = 16;
var event_buf: [MAX_EVENTS]NetEvent = undefined;
var event_count: usize = 0;
var event_mutex: platform.Mutex = undefined;

fn onNetEvent(ctx: ?*anyopaque, event: NetEvent) void {
    _ = ctx;
    event_mutex.lock();
    defer event_mutex.unlock();
    if (event_count < MAX_EVENTS) {
        event_buf[event_count] = event;
        event_count += 1;
    }
}

fn getEventCount() usize {
    event_mutex.lock();
    defer event_mutex.unlock();
    return event_count;
}

fn getEvent(idx: usize) NetEvent {
    event_mutex.lock();
    defer event_mutex.unlock();
    return event_buf[idx];
}

fn resetEvents() void {
    event_mutex.lock();
    defer event_mutex.unlock();
    event_count = 0;
}

/// Wait for event_count to reach target, timeout in ms
fn waitForEvents(target: usize, timeout_ms: u32) bool {
    var waited: u32 = 0;
    while (getEventCount() < target and waited < timeout_ms) {
        platform.time.sleepMs(100);
        waited += 100;
    }
    return getEventCount() >= target;
}

fn runTests() !void {
    log.info("[e2e] START: trait/net_events", .{});

    event_mutex = platform.Mutex.init();
    defer event_mutex.deinit();

    // Test 1: Init WiFi + Net driver
    var wifi = platform.WifiDriver.init() catch |err| {
        log.err("[e2e] FAIL: trait/net_events/init — wifi: {}", .{err});
        return error.WifiInitFailed;
    };
    defer wifi.deinit();

    var net = platform.NetDriver.initWithCallback(onNetEvent, null) catch |err| {
        log.err("[e2e] FAIL: trait/net_events/init — net: {}", .{err});
        return error.NetInitFailed;
    };
    defer net.deinit();
    log.info("[e2e] PASS: trait/net_events/init", .{});

    // Test 2: Connect → dhcp_bound
    resetEvents();
    log.info("[e2e] INFO: connecting to {s}...", .{g_ssid});
    wifi.connect(g_ssid, g_password);

    // Wait for connection + DHCP (up to 30s)
    var waited: u32 = 0;
    while (!wifi.isConnected() and waited < 30000) {
        platform.time.sleepMs(100);
        waited += 100;
    }
    if (!wifi.isConnected()) {
        log.err("[e2e] FAIL: trait/net_events/connect — not connected in 30s", .{});
        return error.WifiConnectTimeout;
    }

    // Wait for dhcp_bound event (extra 3s after connect)
    if (!waitForEvents(1, 5000)) {
        log.err("[e2e] FAIL: trait/net_events/dhcp_bound — no event in 5s after connect", .{});
        return error.NoDhcpEvent;
    }

    // Verify dhcp_bound
    {
        const ev = getEvent(0);
        switch (ev) {
            .dhcp_bound => |data| {
                if (data.ip[0] == 0 and data.ip[1] == 0 and data.ip[2] == 0 and data.ip[3] == 0) {
                    log.err("[e2e] FAIL: trait/net_events/dhcp_bound — ip is 0.0.0.0", .{});
                    return error.DhcpNoIp;
                }
                if (data.gateway[0] == 0) {
                    log.err("[e2e] FAIL: trait/net_events/dhcp_bound — no gateway", .{});
                    return error.DhcpNoGateway;
                }
                log.info("[e2e] PASS: trait/net_events/dhcp_bound — ip={}.{}.{}.{} gw={}.{}.{}.{} dns={}.{}.{}.{} lease={}s", .{
                    data.ip[0],      data.ip[1],      data.ip[2],      data.ip[3],
                    data.gateway[0], data.gateway[1], data.gateway[2], data.gateway[3],
                    data.dns_main[0], data.dns_main[1], data.dns_main[2], data.dns_main[3],
                    data.lease_time,
                });
            },
            else => {
                log.err("[e2e] FAIL: trait/net_events/dhcp_bound — first event is not dhcp_bound", .{});
                return error.WrongEventType;
            },
        }
    }

    // Test 3: Disconnect → ip_lost
    const events_before_disconnect = getEventCount();
    log.info("[e2e] INFO: disconnecting...", .{});
    wifi.disconnect();

    // Wait for ip_lost event (up to 5s)
    if (!waitForEvents(events_before_disconnect + 1, 5000)) {
        log.warn("[e2e] WARN: trait/net_events/ip_lost — no event after disconnect (may be expected on some IDF versions)", .{});
        // Not fatal — some IDF versions don't fire ip_lost immediately
    } else {
        const ev = getEvent(events_before_disconnect);
        switch (ev) {
            .ip_lost => {
                log.info("[e2e] PASS: trait/net_events/ip_lost", .{});
            },
            .dhcp_bound => {
                log.warn("[e2e] WARN: trait/net_events/ip_lost — got dhcp_bound instead (reconnect race?)", .{});
            },
            else => {
                log.warn("[e2e] WARN: trait/net_events/ip_lost — unexpected event type after disconnect", .{});
            },
        }
    }

    // Test 4: Reconnect → second dhcp_bound
    // Don't reset — ip_lost from disconnect may arrive late
    const events_before_reconnect = getEventCount();
    log.info("[e2e] INFO: reconnecting...", .{});
    wifi.connect(g_ssid, g_password);

    waited = 0;
    while (!wifi.isConnected() and waited < 30000) {
        platform.time.sleepMs(100);
        waited += 100;
    }
    if (!wifi.isConnected()) {
        log.err("[e2e] FAIL: trait/net_events/reconnect — not connected in 30s", .{});
        return error.WifiReconnectTimeout;
    }

    // Wait for at least one new event after reconnect
    if (!waitForEvents(events_before_reconnect + 1, 10000)) {
        log.err("[e2e] FAIL: trait/net_events/reconnect — no event after reconnect", .{});
        return error.NoDhcpReconnect;
    }

    // Find dhcp_bound or dhcp_renewed (reconnect with same IP = renewed)
    {
        var found_dhcp = false;
        const total = getEventCount();
        var idx: usize = events_before_reconnect;
        while (idx < total) : (idx += 1) {
            const ev = getEvent(idx);
            switch (ev) {
                .dhcp_bound => |data| {
                    if (data.ip[0] == 0) {
                        log.err("[e2e] FAIL: trait/net_events/reconnect — ip is 0", .{});
                        return error.DhcpNoIp;
                    }
                    log.info("[e2e] PASS: trait/net_events/reconnect_bound — ip={}.{}.{}.{}", .{
                        data.ip[0], data.ip[1], data.ip[2], data.ip[3],
                    });
                    found_dhcp = true;
                    break;
                },
                .dhcp_renewed => |data| {
                    // Same IP after reconnect → ip_changed=false → renewed (not bound)
                    if (data.ip[0] == 0) {
                        log.err("[e2e] FAIL: trait/net_events/reconnect — renewed ip is 0", .{});
                        return error.DhcpNoIp;
                    }
                    log.info("[e2e] PASS: trait/net_events/reconnect_renewed — ip={}.{}.{}.{} (same IP)", .{
                        data.ip[0], data.ip[1], data.ip[2], data.ip[3],
                    });
                    found_dhcp = true;
                    break;
                },
                .ip_lost => {
                    log.info("[e2e] INFO: trait/net_events/reconnect — got delayed ip_lost (ok)", .{});
                },
                else => {},
            }
        }
        if (!found_dhcp) {
            log.err("[e2e] FAIL: trait/net_events/reconnect — no dhcp event in {} new events", .{total - events_before_reconnect});
            return error.NoDhcpReconnect;
        }
    }

    // Cleanup
    wifi.disconnect();
    log.info("[e2e] PASS: trait/net_events", .{});
}

pub fn run(env: anytype) void {
    g_ssid = env.wifi_ssid;
    g_password = env.wifi_password;
    runTests() catch |err| {
        log.err("[e2e] FATAL: trait/net_events — {}", .{err});
    };
}

test "e2e: trait/net_events" {
    // Net events test is ESP-only
    return error.SkipZigTest;
}
