//! HTTPS Speed Test - Platform Independent
//!
//! Tests HTTPS download speed using pure Zig TLS client.
//! DNS server comes from DHCP event (no net_impl.getDns).

const std = @import("std");
const trait = @import("trait");
const tls = @import("tls");
const dns = @import("dns");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);

const BUILD_TAG = "https_speed_test_v3_cross_platform";

/// DNS Resolver using platform socket
const DnsResolver = dns.Resolver(Board.socket);

const AppState = enum { connecting, connected, running_tests, done };

/// Run HTTPS test against public server
fn runPublicTest(
    dns_server: [4]u8,
    host: []const u8,
    path: []const u8,
    test_name: []const u8,
    skip_verify: bool,
) void {
    log.info("", .{});
    log.info("--- {s} ---", .{test_name});
    log.info("Host: {s}, Path: {s}", .{ host, path });

    const start_ms = Board.time.getTimeMs();

    // DNS resolve
    log.info("DNS resolving via {}.{}.{}.{}...", .{ dns_server[0], dns_server[1], dns_server[2], dns_server[3] });
    var resolver = DnsResolver{
        .server = dns_server,
        .protocol = .udp,
        .timeout_ms = 5000,
    };

    const server_ip = resolver.resolve(host) catch |err| {
        log.err("DNS resolve failed: {}", .{err});
        return;
    };
    log.info("Resolved: {}.{}.{}.{}", .{ server_ip[0], server_ip[1], server_ip[2], server_ip[3] });

    // Create socket
    var sock = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };

    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    // Connect to HTTPS (port 443)
    log.info("Connecting...", .{});
    sock.connect(server_ip, 443) catch |err| {
        log.err("Connect failed: {}", .{err});
        sock.close();
        return;
    };
    log.info("TCP connected", .{});

    // TLS handshake
    const Crypto = Board.crypto;
    const TlsClient = tls.Client(Board.socket, Crypto);

    var tls_client = TlsClient.init(&sock, .{
        .allocator = platform.allocator,
        .hostname = host,
        .skip_verify = skip_verify,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        sock.close();
        return;
    };

    const handshake_start = Board.time.getTimeMs();
    log.info("TLS handshake ({s})...", .{if (skip_verify) "no verify" else "cert verify"});
    tls_client.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls_client.deinit();
        return;
    };
    const handshake_ms = Board.time.getTimeMs() - handshake_start;
    log.info("TLS handshake: {} ms", .{handshake_ms});

    // HTTP request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n\r\n", .{ path, host }) catch {
        log.err("Request too long", .{});
        tls_client.deinit();
        return;
    };

    _ = tls_client.send(request) catch |err| {
        log.err("TLS send failed: {}", .{err});
        tls_client.deinit();
        return;
    };

    // Receive response
    var total_bytes: usize = 0;
    var last_print: usize = 0;
    var recv_buf: [8192]u8 = undefined;
    var header_done = false;
    var body_start_ms: u64 = 0;

    while (true) {
        const n = tls_client.recv(&recv_buf) catch |err| {
            if (err == error.EndOfStream) break;
            log.err("TLS recv error: {}", .{err});
            break;
        };
        if (n == 0) break;

        if (body_start_ms == 0) body_start_ms = Board.time.getTimeMs();

        if (!header_done) {
            if (std.mem.indexOf(u8, recv_buf[0..n], "\r\n\r\n")) |pos| {
                total_bytes += n - (pos + 4);
                header_done = true;
            }
        } else {
            total_bytes += n;
        }

        if (total_bytes - last_print >= 100 * 1024) {
            const elapsed_ms = Board.time.getTimeMs() - body_start_ms;
            const speed = if (elapsed_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / elapsed_ms)) else 0;
            log.info("Progress: {} KB ({} KB/s)", .{ total_bytes / 1024, speed });
            last_print = total_bytes;
        }
    }

    tls_client.deinit();

    const end_ms = Board.time.getTimeMs();
    const body_ms = if (body_start_ms > 0) end_ms - body_start_ms else end_ms - start_ms;
    const speed = if (body_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / body_ms)) else 0;

    log.info("Downloaded: {} bytes in {} ms (handshake: {} ms)", .{ total_bytes, end_ms - start_ms, handshake_ms });
    log.info("Speed: {} KB/s", .{speed});
}

pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  HTTPS Speed Test", .{});
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
                .wifi => |wifi_event| switch (wifi_event) {
                    .connected => log.info("WiFi connected (waiting for IP...)", .{}),
                    .disconnected => |reason| {
                        log.warn("WiFi disconnected: {}", .{reason});
                        state = .connecting;
                    },
                    .connection_failed => |reason| {
                        log.err("WiFi failed: {}", .{reason});
                        return;
                    },
                    else => {},
                },
                .net => |net_event| switch (net_event) {
                    .dhcp_bound, .dhcp_renewed => |info| {
                        log.info("Got IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        log.info("DNS: {}.{}.{}.{}", .{ info.dns_main[0], info.dns_main[1], info.dns_main[2], info.dns_main[3] });
                        dhcp_dns = info.dns_main;
                        state = .connected;
                    },
                    .ip_lost => {
                        log.warn("IP lost", .{});
                        state = .connecting;
                    },
                    else => {},
                },
                else => {},
            }
        }

        switch (state) {
            .connecting => {},
            .connected => {
                Board.time.sleepMs(1000);
                const dns_server = if (dhcp_dns[0] != 0) dhcp_dns else [4]u8{ 223, 5, 5, 5 };

                // Small test first
                runPublicTest(dns_server, "httpbin.org", "/get", "HTTPS small (httpbin)", true);
                Board.time.sleepMs(2000);

                // Larger download test (~100KB)
                runPublicTest(dns_server, "httpbin.org", "/bytes/102400", "HTTPS 100KB download", true);

                state = .running_tests;
            },
            .running_tests => {
                log.info("", .{});
                log.info("=== All Tests Complete ===", .{});
                state = .done;
            },
            .done => {},
        }

        Board.time.sleepMs(10);
    }
}
