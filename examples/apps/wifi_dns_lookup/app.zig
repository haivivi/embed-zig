//! WiFi DNS Lookup Example - Platform Independent
//!
//! Demonstrates WiFi connection and DNS resolution using HAL abstraction.
//! Supports UDP, TCP, and HTTPS (DoH) DNS protocols.

const std = @import("std");
const dns = @import("dns");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const BUILD_TAG = "wifi_dns_lookup_hal_v1";

/// DNS Resolver using platform socket
const Resolver = dns.Resolver(Board.socket);

fn printMemoryStats() void {
    // Memory stats are platform-specific, skip in generic app
    log.info("=== DNS Lookup Test Starting ===", .{});
}

fn dnsLookupTest() void {
    log.info("", .{});
    log.info("=== DNS Lookup Test ===", .{});

    const test_domains = [_][]const u8{
        "www.google.com",
        "www.baidu.com",
        "cloudflare.com",
        "github.com",
    };

    // Test with UDP - AliDNS
    log.info("--- UDP DNS (223.5.5.5 AliDNS) ---", .{});
    var udp_resolver = Resolver{
        .server = .{ 223, 5, 5, 5 },
        .protocol = .udp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const result = udp_resolver.resolve(domain);
        if (result) |ip| {
            var ip_buf: [16]u8 = undefined;
            const ip_str = dns.formatIpv4(ip, &ip_buf);
            log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with TCP - AliDNS
    log.info("--- TCP DNS (223.5.5.5 AliDNS) ---", .{});
    var tcp_resolver = Resolver{
        .server = .{ 223, 5, 5, 5 },
        .protocol = .tcp,
        .timeout_ms = 5000,
    };

    for (test_domains) |domain| {
        const result = tcp_resolver.resolve(domain);
        if (result) |ip| {
            var ip_buf: [16]u8 = undefined;
            const ip_str = dns.formatIpv4(ip, &ip_buf);
            log.info("{s} => {s}", .{ domain, ip_str });
        } else |err| {
            log.err("{s} => failed: {}", .{ domain, err });
        }
    }

    // Test with backup AliDNS
    log.info("--- UDP DNS (223.6.6.6 AliDNS Backup) ---", .{});
    var ali_resolver = Resolver{
        .server = .{ 223, 6, 6, 6 },
        .protocol = .udp,
    };

    const ali_result = ali_resolver.resolve("example.com");
    if (ali_result) |ip| {
        var ip_buf: [16]u8 = undefined;
        const ip_str = dns.formatIpv4(ip, &ip_buf);
        log.info("example.com => {s}", .{ip_str});
    } else |err| {
        log.err("example.com => failed: {}", .{err});
    }
}

/// Run with env from platform
pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  WiFi DNS Lookup - HAL Version", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    printMemoryStats();

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    // Connect to WiFi
    log.info("", .{});
    log.info("Connecting to WiFi...", .{});
    log.info("SSID: {s}", .{env.wifi_ssid});

    b.wifi.connect(env.wifi_ssid, env.wifi_password) catch |err| {
        log.err("WiFi connect failed: {}", .{err});
        return;
    };

    // Print IP address
    if (b.wifi.getIpAddress()) |ip| {
        var ip_buf: [16]u8 = undefined;
        const ip_str = dns.formatIpv4(ip, &ip_buf);
        log.info("Connected! IP: {s}", .{ip_str});
    } else {
        log.info("Connected! (IP not available)", .{});
    }

    // Run DNS lookup tests
    dnsLookupTest();

    // Keep running
    log.info("", .{});
    log.info("=== Test Complete ===", .{});

    while (true) {
        Board.time.sleepMs(10000);
        log.info("Still running...", .{});
    }
}
