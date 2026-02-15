//! HTTPS Speed Test - Local & Public Server Test
//!
//! Tests HTTPS download speed using pure Zig TLS client.
//! - Local server test (self-signed cert, skip_verify)
//! - Public server test (ESP Bundle cert verification)

const std = @import("std");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const esp = @import("esp");
const idf = esp.idf;
const tls = @import("tls");
const dns = @import("dns");
const allocator = idf.heap.psram;

const BUILD_TAG = "https_speed_test_v2_esp_bundle";

/// CA Store type from Crypto (for ESP Bundle)
const CaStore = Board.crypto.x509.CaStore;

/// DNS Resolver for hostname lookup
const DnsResolver = dns.Resolver(Board.socket, void);

/// Application state machine
const AppState = enum {
    connecting,
    connected,
    running_tests,
    done,
};

/// Parse IP address string to bytes (e.g., "192.168.4.1" -> [4]u8)
fn parseIpAddress(ip_str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, ip_str, '.');
    for (&result) |*octet| {
        const octet_str = it.next() orelse return null;
        octet.* = std.fmt.parseInt(u8, octet_str, 10) catch return null;
    }
    // Ensure no extra parts
    if (it.next() != null) return null;
    return result;
}

/// Run HTTPS test against local server
fn runLocalTest(server_ip: [4]u8, port: u16, path: []const u8, test_name: []const u8) void {
    log.info("", .{});
    log.info("--- {s} ---", .{test_name});
    log.info("Server: {}.{}.{}.{}:{}", .{ server_ip[0], server_ip[1], server_ip[2], server_ip[3], port });
    log.info("Path: {s}", .{path});

    const start_ms = Board.time.getTimeMs();

    // Create socket
    var sock = idf.net.socket.Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };

    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    // Connect
    log.info("Connecting...", .{});
    sock.connect(server_ip, port) catch |err| {
        log.err("Connect failed: {}", .{err});
        sock.close();
        return;
    };
    log.info("TCP connected", .{});

    // TLS handshake (using ESP32 crypto suite with hardware acceleration)
    // Crypto includes Rng, so only 2 type parameters needed
    const Crypto = Board.crypto;
    const TlsClient = tls.Client(idf.net.socket.Socket, Crypto, idf.runtime);

    var tls_client = TlsClient.init(&sock, .{
        .allocator = allocator,
        .hostname = "localhost", // SNI
        .skip_verify = true, // Self-signed cert
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        sock.close();
        return;
    };

    const handshake_start = Board.time.getTimeMs();
    log.info("TLS handshake...", .{});
    tls_client.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls_client.deinit();
        return;
    };
    const handshake_ms = Board.time.getTimeMs() - handshake_start;
    log.info("TLS handshake: {} ms", .{handshake_ms});

    // Build HTTP request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: localhost\r\nUser-Agent: ESP32-ZigTLS/1.0\r\nConnection: close\r\n\r\n", .{path}) catch {
        log.err("Request too long", .{});
        tls_client.deinit();
        return;
    };

    // Send request
    _ = tls_client.send(request) catch |err| {
        log.err("TLS send failed: {}", .{err});
        tls_client.deinit();
        return;
    };
    log.info("Request sent", .{});

    // Receive response with streaming (larger buffer for throughput)
    var total_bytes: usize = 0;
    var last_print: usize = 0;
    var recv_buf: [16384]u8 = undefined; // 16KB buffer
    var header_done = false;
    var status_logged = false;
    var first_chunk = true;
    var body_start_ms: u64 = 0;

    while (true) {
        const n = tls_client.recv(&recv_buf) catch |err| {
            if (err == error.EndOfStream) break;
            log.err("TLS recv error: {}", .{err});
            break;
        };
        if (n == 0) break;

        if (first_chunk) {
            body_start_ms = Board.time.getTimeMs();
            first_chunk = false;
        }

        if (!header_done) {
            // Log status code once
            if (!status_logged) {
                if (std.mem.indexOf(u8, recv_buf[0..n], "HTTP/1.")) |http_pos| {
                    const status_start = http_pos + 9;
                    if (status_start + 3 <= n) {
                        if (std.fmt.parseInt(u16, recv_buf[status_start .. status_start + 3], 10)) |code| {
                            log.info("HTTP Status: {}", .{code});
                            status_logged = true;
                        } else |_| {}
                    }
                }
            }

            // Skip HTTP header
            if (std.mem.indexOf(u8, recv_buf[0..n], "\r\n\r\n")) |pos| {
                total_bytes += n - (pos + 4);
                header_done = true;
            }
        } else {
            total_bytes += n;
        }

        // Progress every 100KB
        if (total_bytes - last_print >= 100 * 1024) {
            const elapsed_ms = Board.time.getTimeMs() - body_start_ms;
            const speed = if (elapsed_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / elapsed_ms)) else 0;
            log.info("Progress: {} KB ({} KB/s)", .{ total_bytes / 1024, speed });
            last_print = total_bytes;
        }
    }

    tls_client.deinit();

    const end_ms = Board.time.getTimeMs();
    const total_ms = end_ms - start_ms;
    const body_ms = if (body_start_ms > 0) end_ms - body_start_ms else total_ms;
    const speed = if (body_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / body_ms)) else 0;

    log.info("", .{});
    log.info("=== Results ===", .{});
    log.info("Downloaded: {} bytes", .{total_bytes});
    log.info("Total time: {} ms (handshake: {} ms, transfer: {} ms)", .{ total_ms, handshake_ms, body_ms });
    log.info("Speed: {} KB/s ({} Kbps)", .{ speed, speed * 8 });
}

/// Run HTTPS test against public server
fn runPublicTest(host: []const u8, path: []const u8, test_name: []const u8, skip_verify: bool) void {
    log.info("", .{});
    log.info("--- {s} ---", .{test_name});
    log.info("Host: {s}", .{host});
    log.info("Path: {s}", .{path});

    const start_ms = Board.time.getTimeMs();

    // DNS resolve using system DNS (from DHCP)
    log.info("DNS resolving...", .{});
    const dns_servers = Board.net_impl.getDns();
    const dns_server = if (dns_servers[0][0] != 0) dns_servers[0] else .{ 223, 5, 5, 5 }; // Fallback to AliDNS
    log.info("Using DNS: {}.{}.{}.{}", .{ dns_server[0], dns_server[1], dns_server[2], dns_server[3] });

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
    var sock = idf.net.socket.Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };

    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    // Connect to port 443 (HTTPS)
    log.info("Connecting...", .{});
    sock.connect(server_ip, 443) catch |err| {
        log.err("Connect failed: {}", .{err});
        sock.close();
        return;
    };
    log.info("TCP connected", .{});

    // TLS handshake with ESP Bundle certificate verification
    const Crypto = Board.crypto;
    const TlsClient = tls.Client(idf.net.socket.Socket, Crypto, idf.runtime);

    var tls_client = TlsClient.init(&sock, .{
        .allocator = allocator,
        .hostname = host,
        .ca_store = if (skip_verify) .insecure else .esp_bundle,
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
    log.info("TLS handshake: {} ms ({s})", .{ handshake_ms, if (skip_verify) "no verify" else "verified" });

    // Build HTTP request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: ESP32-ZigTLS/1.0\r\nConnection: close\r\n\r\n", .{ path, host }) catch {
        log.err("Request too long", .{});
        tls_client.deinit();
        return;
    };

    // Send request
    _ = tls_client.send(request) catch |err| {
        log.err("TLS send failed: {}", .{err});
        tls_client.deinit();
        return;
    };
    log.info("Request sent", .{});

    // Receive response
    var total_bytes: usize = 0;
    var last_print: usize = 0;
    var recv_buf: [16384]u8 = undefined;
    var header_done = false;
    var status_logged = false;
    var first_chunk = true;
    var body_start_ms: u64 = 0;

    while (true) {
        const n = tls_client.recv(&recv_buf) catch |err| {
            if (err == error.EndOfStream) break;
            log.err("TLS recv error: {}", .{err});
            break;
        };
        if (n == 0) break;

        if (first_chunk) {
            body_start_ms = Board.time.getTimeMs();
            first_chunk = false;
        }

        if (!header_done) {
            if (!status_logged) {
                if (std.mem.indexOf(u8, recv_buf[0..n], "HTTP/1.")) |http_pos| {
                    const status_start = http_pos + 9;
                    if (status_start + 3 <= n) {
                        if (std.fmt.parseInt(u16, recv_buf[status_start .. status_start + 3], 10)) |code| {
                            log.info("HTTP Status: {}", .{code});
                            status_logged = true;
                        } else |_| {}
                    }
                }
            }

            if (std.mem.indexOf(u8, recv_buf[0..n], "\r\n\r\n")) |pos| {
                total_bytes += n - (pos + 4);
                header_done = true;
            }
        } else {
            total_bytes += n;
        }

        // Progress every 100KB
        if (total_bytes - last_print >= 100 * 1024) {
            const elapsed_ms = Board.time.getTimeMs() - body_start_ms;
            const speed = if (elapsed_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / elapsed_ms)) else 0;
            log.info("Progress: {} KB ({} KB/s)", .{ total_bytes / 1024, speed });
            last_print = total_bytes;
        }
    }

    tls_client.deinit();

    const end_ms = Board.time.getTimeMs();
    const total_ms = end_ms - start_ms;
    const body_ms = if (body_start_ms > 0) end_ms - body_start_ms else total_ms;
    const speed = if (body_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / body_ms)) else 0;

    log.info("", .{});
    log.info("=== Results ({s}) ===", .{if (skip_verify) "No Verify" else "Verified"});
    log.info("Downloaded: {} bytes", .{total_bytes});
    log.info("Total time: {} ms (handshake: {} ms, transfer: {} ms)", .{ total_ms, handshake_ms, body_ms });
    log.info("Speed: {} KB/s ({} Kbps)", .{ speed, speed * 8 });
}

/// Run HTTPS test with separate DNS host and TLS host (for CDN testing)
fn runPublicTestWithHost(dns_host: []const u8, tls_host: []const u8, path: []const u8, test_name: []const u8, skip_verify: bool) void {
    log.info("", .{});
    log.info("--- {s} ---", .{test_name});
    log.info("DNS Host: {s}", .{dns_host});
    log.info("TLS Host: {s}", .{tls_host});
    log.info("Path: {s}", .{path});

    const start_ms = Board.time.getTimeMs();

    // DNS resolve using system DNS (from DHCP)
    log.info("DNS resolving...", .{});
    const dns_servers = Board.net_impl.getDns();
    const dns_server = if (dns_servers[0][0] != 0) dns_servers[0] else .{ 223, 5, 5, 5 }; // Fallback to AliDNS
    log.info("Using DNS: {}.{}.{}.{}", .{ dns_server[0], dns_server[1], dns_server[2], dns_server[3] });

    var resolver = DnsResolver{
        .server = dns_server,
        .protocol = .udp,
        .timeout_ms = 5000,
    };

    const server_ip = resolver.resolve(dns_host) catch |err| {
        log.err("DNS resolve failed: {}", .{err});
        return;
    };
    log.info("Resolved: {}.{}.{}.{}", .{ server_ip[0], server_ip[1], server_ip[2], server_ip[3] });

    // Create socket
    var sock = idf.net.socket.Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };

    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    // Connect to port 443 (HTTPS)
    log.info("Connecting...", .{});
    sock.connect(server_ip, 443) catch |err| {
        log.err("Connect failed: {}", .{err});
        sock.close();
        return;
    };
    log.info("TCP connected", .{});

    // TLS handshake with tls_host for SNI
    const Crypto = Board.crypto;
    const TlsClient = tls.Client(idf.net.socket.Socket, Crypto, idf.runtime);

    var tls_client = TlsClient.init(&sock, .{
        .allocator = allocator,
        .hostname = tls_host, // Use original domain for SNI
        .ca_store = if (skip_verify) .insecure else .esp_bundle,
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
    log.info("TLS handshake: {} ms ({s})", .{ handshake_ms, if (skip_verify) "no verify" else "verified" });

    // Build HTTP request using tls_host
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: ESP32-ZigTLS/1.0\r\nConnection: close\r\n\r\n", .{ path, tls_host }) catch {
        log.err("Request too long", .{});
        tls_client.deinit();
        return;
    };

    // Send request
    _ = tls_client.send(request) catch |err| {
        log.err("TLS send failed: {}", .{err});
        tls_client.deinit();
        return;
    };
    log.info("Request sent", .{});

    // Receive response
    var total_bytes: usize = 0;
    var last_print: usize = 0;
    var recv_buf: [16384]u8 = undefined;
    var header_done = false;
    var status_logged = false;
    var first_chunk = true;
    var body_start_ms: u64 = 0;

    while (true) {
        const n = tls_client.recv(&recv_buf) catch |err| {
            if (err == error.EndOfStream) break;
            log.err("TLS recv error: {}", .{err});
            break;
        };
        if (n == 0) break;

        if (first_chunk) {
            body_start_ms = Board.time.getTimeMs();
            first_chunk = false;
        }

        if (!header_done) {
            if (!status_logged) {
                if (std.mem.indexOf(u8, recv_buf[0..n], "HTTP/1.")) |http_pos| {
                    const status_start = http_pos + 9;
                    if (status_start + 3 <= n) {
                        if (std.fmt.parseInt(u16, recv_buf[status_start .. status_start + 3], 10)) |code| {
                            log.info("HTTP Status: {}", .{code});
                            status_logged = true;
                        } else |_| {}
                    }
                }
            }

            if (std.mem.indexOf(u8, recv_buf[0..n], "\r\n\r\n")) |pos| {
                total_bytes += n - (pos + 4);
                header_done = true;
            }
        } else {
            total_bytes += n;
        }

        // Progress every 100KB
        if (total_bytes - last_print >= 100 * 1024) {
            const elapsed_ms = Board.time.getTimeMs() - body_start_ms;
            const speed = if (elapsed_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / elapsed_ms)) else 0;
            log.info("Progress: {} KB ({} KB/s)", .{ total_bytes / 1024, speed });
            last_print = total_bytes;
        }
    }

    tls_client.deinit();

    const end_ms = Board.time.getTimeMs();
    const total_ms = end_ms - start_ms;
    const body_ms = if (body_start_ms > 0) end_ms - body_start_ms else total_ms;
    const speed = if (body_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / body_ms)) else 0;

    log.info("", .{});
    log.info("=== Results ({s}) ===", .{if (skip_verify) "No Verify" else "Verified"});
    log.info("Downloaded: {} bytes", .{total_bytes});
    log.info("Total time: {} ms (handshake: {} ms, transfer: {} ms)", .{ total_ms, handshake_ms, body_ms });
    log.info("Speed: {} KB/s ({} Kbps)", .{ speed, speed * 8 });
}

/// Print memory status
fn printMemoryStatus(tag: []const u8) void {
    const internal_stats = idf.heap.getInternalStats();
    const psram_stats = idf.heap.getPsramStats();
    log.info("[MEM:{s}] IRAM: {}KB free | PSRAM: {}KB free", .{ tag, internal_stats.free / 1024, psram_stats.free / 1024 });
}

/// Run HTTPS speed test with env from platform
pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  HTTPS Speed Test - Public CDN", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    // Start WiFi connection (non-blocking)
    log.info("", .{});
    log.info("Connecting to WiFi...", .{});
    log.info("SSID: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var state: AppState = .connecting;

    // Event loop
    while (Board.isRunning()) {
        // Process events
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    // WiFi 802.11 layer events
                    switch (wifi_event) {
                        .connected => {
                            log.info("WiFi connected to AP (waiting for IP...)", .{});
                        },
                        .disconnected => |reason| {
                            log.warn("WiFi disconnected: {}", .{reason});
                            state = .connecting;
                        },
                        .connection_failed => |reason| {
                            log.err("WiFi connection failed: {}", .{reason});
                            return;
                        },
                        .scan_done => {},
                        .rssi_low => {},
                        .ap_sta_connected, .ap_sta_disconnected => {},
                    }
                },
                .net => |net_event| {
                    // IP layer events
                    switch (net_event) {
                        .dhcp_bound, .dhcp_renewed => |info| {
                            const ip = info.ip;
                            log.info("Got IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
                            log.info("DNS: {}.{}.{}.{}", .{ info.dns_main[0], info.dns_main[1], info.dns_main[2], info.dns_main[3] });
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

        // State machine
        switch (state) {
            .connecting => {
                // Wait for connection
            },
            .connected => {
                // Run tests once connected
                Board.time.sleepMs(1000);
                printMemoryStatus("START");

                // Skip local tests - go directly to public HTTPS tests
                log.info("", .{});
                log.info("========================================", .{});
                log.info("  Public HTTPS Tests (ESP Bundle)", .{});
                log.info("========================================", .{});

                // Haivivi OTA - compare with/without cert verification (direct CDN)
                runPublicTestWithHost("static.haivivi.cn.volcgslb-mlt.com", "static.haivivi.cn", "/public/firmwares/h200-s3/318_zh/ota.bin", "OTA CDN (Verified)", false);
                Board.time.sleepMs(2000);
                printMemoryStatus("AFTER-VERIFIED");

                runPublicTestWithHost("static.haivivi.cn.volcgslb-mlt.com", "static.haivivi.cn", "/public/firmwares/h200-s3/318_zh/ota.bin", "OTA CDN (No Verify)", true);

                state = .running_tests;
            },
            .running_tests => {
                log.info("", .{});
                log.info("=== All Tests Complete ===", .{});
                printMemoryStatus("END");
                state = .done;
            },
            .done => {
                // Idle
            },
        }

        Board.time.sleepMs(10);
    }
}
