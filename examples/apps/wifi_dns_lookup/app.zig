//! WiFi DNS Lookup Example - DNS Protocol Test
//!
//! Tests UDP and TCP DNS resolution. DoH (DNS over HTTPS) is optional
//! and requires platform crypto support.

const std = @import("std");
const dns = @import("dns");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const BUILD_TAG = "wifi_dns_v4_cross_platform";

/// DNS Resolver (UDP/TCP only)
const Resolver = dns.Resolver(Board.socket, void);

/// Test domains
const test_domains = [_][]const u8{
    "www.google.com",
    "www.baidu.com",
    "example.com",
    "github.com",
};

/// DHCP DNS Test - uses DNS server from DHCP lease
fn testDhcpDns(dhcp_dns: [4]u8) void {
    log.info("", .{});
    var dns_buf: [16]u8 = undefined;
    log.info("=== DHCP DNS Test (from DHCP: {s}) ===", .{dns.formatIpv4(dhcp_dns, &dns_buf)});

    // Check if we got a valid DNS from DHCP
    if (dhcp_dns[0] == 0 and dhcp_dns[1] == 0 and dhcp_dns[2] == 0 and dhcp_dns[3] == 0) {
        log.warn("No DNS server from DHCP, skipping test", .{});
        return;
    }

    var resolver = Resolver{
        .server = dhcp_dns,
        .protocol = .udp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const start = Board.time.nowMs();
        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.nowMs() - start;
            var buf: [16]u8 = undefined;
            log.info("[DHCP_DNS] {s} => {s} ({d}ms)", .{ domain, dns.formatIpv4(ip, &buf), duration });
        } else |err| {
            log.err("[DHCP_DNS] {s} => FAILED: {}", .{ domain, err });
        }
    }
}

/// UDP DNS Test
fn testUdpDns() void {
    log.info("", .{});
    log.info("=== UDP DNS Test (223.5.5.5 AliDNS) ===", .{});

    var resolver = Resolver{
        .server = .{ 223, 5, 5, 5 },
        .protocol = .udp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const start = Board.time.nowMs();
        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.nowMs() - start;
            var buf: [16]u8 = undefined;
            log.info("{s} => {s} ({d}ms)", .{ domain, dns.formatIpv4(ip, &buf), duration });
        } else |err| {
            log.err("{s} => FAILED: {}", .{ domain, err });
        }
    }
}

/// TCP DNS Test
fn testTcpDns() void {
    log.info("", .{});
    log.info("=== TCP DNS Test (223.5.5.5 AliDNS) ===", .{});

    var resolver = Resolver{
        .server = .{ 223, 5, 5, 5 },
        .protocol = .tcp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const start = Board.time.nowMs();
        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.nowMs() - start;
            var buf: [16]u8 = undefined;
            log.info("{s} => {s} ({d}ms)", .{ domain, dns.formatIpv4(ip, &buf), duration });
        } else |err| {
            log.err("{s} => FAILED: {}", .{ domain, err });
        }
    }
}

/// Application state machine
const AppState = enum {
    connecting,
    connected,
    testing,
    done,
};

/// Run with env from main (contains WiFi credentials)
pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  WiFi DNS Lookup - UDP/TCP Test", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    log.info("Connecting to WiFi: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var state: AppState = .connecting;
    var dhcp_dns: [4]u8 = .{ 0, 0, 0, 0 };

    while (Board.isRunning()) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .connected => log.info("WiFi connected to AP (waiting for IP...)", .{}),
                        .disconnected => |reason| {
                            log.warn("WiFi disconnected: {}", .{reason});
                            state = .connecting;
                        },
                        .connection_failed => |reason| {
                            log.err("WiFi failed: {}", .{reason});
                            return;
                        },
                        else => {},
                    }
                },
                .net => |net_event| {
                    switch (net_event) {
                        .dhcp_bound, .dhcp_renewed => |info| {
                            var buf: [16]u8 = undefined;
                            log.info("Got IP: {s}", .{dns.formatIpv4(info.ip, &buf)});
                            log.info("DNS: {s}", .{dns.formatIpv4(info.dns_main, &buf)});
                            dhcp_dns = info.dns_main;
                            state = .connected;
                        },
                        .ip_lost => {
                            log.warn("IP lost", .{});
                            state = .connecting;
                        },
                        else => {},
                    }
                },
                else => {},
            }
        }

        switch (state) {
            .connecting => {},
            .connected => {
                Board.time.sleepMs(500);

                // Test 0: DHCP DNS
                testDhcpDns(dhcp_dns);

                // Test 1: UDP DNS (AliDNS)
                testUdpDns();

                // Test 2: TCP DNS (AliDNS)
                testTcpDns();

                state = .testing;
            },
            .testing => {
                log.info("", .{});
                log.info("=== All Tests Complete ===", .{});
                state = .done;
            },
            .done => {},
        }

        Board.time.sleepMs(10);
    }
}
