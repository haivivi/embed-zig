//! WiFi DNS Lookup Example - DNS Protocol Test
//!
//! Tests UDP, TCP, and DoH (DNS over HTTPS) resolution on ESP32.

const std = @import("std");
const dns = @import("net/dns");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const esp = @import("esp");
const heap = esp.idf.heap;

const BUILD_TAG = "wifi_dns_doh_test_v3_cert_verify";

/// DNS Resolver (UDP/TCP only)
const Resolver = dns.Resolver(Board.socket);

/// DoH Resolver with TLS support (uses mbedTLS crypto suite)
const DoHResolver = platform.DnsResolver;

/// CA Store type from Crypto
const CaStore = platform.hw.crypto.x509.CaStore;

/// Test domains
const test_domains = [_][]const u8{
    "www.google.com",
    "www.baidu.com",
    "example.com",
    "github.com",
};

/// Print memory status
fn printMemoryStatus(label: []const u8) void {
    const internal = heap.getInternalStats();
    const psram = heap.getPsramStats();
    const stack = heap.getCurrentTaskStackStats();

    log.info("[MEM:{s}] IRAM: {d}KB free | PSRAM: {d}KB free | Stack HWM: {d}", .{
        label,
        internal.free / 1024,
        psram.free / 1024,
        stack.high_water,
    });
}

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
        const start = Board.time.getTimeMs();
        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.getTimeMs() - start;
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
        const start = Board.time.getTimeMs();
        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.getTimeMs() - start;
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
        const start = Board.time.getTimeMs();
        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.getTimeMs() - start;
            var buf: [16]u8 = undefined;
            log.info("{s} => {s} ({d}ms)", .{ domain, dns.formatIpv4(ip, &buf), duration });
        } else |err| {
            log.err("{s} => FAILED: {}", .{ domain, err });
        }
    }
}

/// DoH (DNS over HTTPS) Test - WITHOUT certificate verification
fn testDoHInsecure() void {
    log.info("", .{});
    log.info("=== DoH Test (INSECURE - no cert verify) ===", .{});
    printMemoryStatus("DoH-INSECURE-START");

    var resolver = DoHResolver{
        .server = .{ 223, 5, 5, 5 }, // AliDNS DoH server IP
        .protocol = .https,
        .doh_host = "dns.alidns.com",
        .allocator = heap.dma,
        .skip_cert_verify = true, // INSECURE: skip verification
        .timeout_ms = 30000,
    };

    // Test single domain
    const domain = "github.com";
    const start = Board.time.getTimeMs();

    if (resolver.resolve(domain)) |ip| {
        const duration = Board.time.getTimeMs() - start;
        var buf: [16]u8 = undefined;
        log.info("[INSECURE] {s} => {s} ({d}ms)", .{ domain, dns.formatIpv4(ip, &buf), duration });
    } else |err| {
        const duration = Board.time.getTimeMs() - start;
        log.err("[INSECURE] {s} => FAILED: {} ({d}ms)", .{ domain, err, duration });
    }
}

/// DoH (DNS over HTTPS) Test - WITH certificate verification (ESP Bundle)
fn testDoH() void {
    log.info("", .{});
    log.info("=== DoH Test (WITH cert verification - ESP Bundle) ===", .{});
    log.info("Using ESP-IDF built-in CA bundle (~130 root CAs)", .{});
    printMemoryStatus("DoH-CERT-START");

    var resolver = DoHResolver{
        .server = .{ 223, 5, 5, 5 }, // AliDNS DoH server IP
        .protocol = .https,
        .doh_host = "dns.alidns.com",
        .allocator = heap.dma,
        .skip_cert_verify = false, // Enable verification
        .ca_store = .esp_bundle, // Use ESP-IDF built-in CA bundle
        .timeout_ms = 30000,
    };

    for (test_domains) |domain| {
        const start = Board.time.getTimeMs();
        printMemoryStatus("DoH-PRE");

        if (resolver.resolve(domain)) |ip| {
            const duration = Board.time.getTimeMs() - start;
            var buf: [16]u8 = undefined;
            log.info("[ESP_BUNDLE] {s} => {s} ({d}ms)", .{ domain, dns.formatIpv4(ip, &buf), duration });
        } else |err| {
            const duration = Board.time.getTimeMs() - start;
            log.err("[ESP_BUNDLE] {s} => FAILED: {} ({d}ms)", .{ domain, err, duration });
        }

        printMemoryStatus("DoH-POST");
        Board.time.sleepMs(500); // Brief pause between requests
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
    log.info("  WiFi DNS Lookup - UDP/TCP/DoH Test", .{});
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
    var dhcp_dns: [4]u8 = .{ 0, 0, 0, 0 }; // DNS from DHCP

    while (Board.isRunning()) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    // WiFi 802.11 layer events
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
                        .scan_done => |info| {
                            log.info("Scan completed: {} APs found", .{info.count});
                        },
                        .rssi_low => |rssi| {
                            log.warn("Signal weak: {} dBm", .{rssi});
                        },
                        .ap_sta_connected, .ap_sta_disconnected => {},
                    }
                },
                .net => |net_event| {
                    // IP layer events
                    switch (net_event) {
                        .dhcp_bound, .dhcp_renewed => |info| {
                            var buf: [16]u8 = undefined;
                            log.info("Got IP: {s}", .{dns.formatIpv4(info.ip, &buf)});
                            log.info("DNS: {s}", .{dns.formatIpv4(info.dns_main, &buf)});
                            dhcp_dns = info.dns_main; // Save DHCP DNS for testing
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
                printMemoryStatus("START");

                // Test 0: DHCP DNS - verify net event correctly captured DHCP DNS
                testDhcpDns(dhcp_dns);

                // Test 1: UDP DNS (AliDNS)
                testUdpDns();

                // Test 2: TCP DNS (AliDNS)
                testTcpDns();

                // Test 3: DoH without cert verification (baseline)
                testDoHInsecure();

                // Test 4: DoH WITH certificate verification
                testDoH();

                state = .testing;
            },
            .testing => {
                log.info("", .{});
                log.info("=== All Tests Complete ===", .{});
                printMemoryStatus("END");
                state = .done;
            },
            .done => {},
        }

        Board.time.sleepMs(10);
    }
}
