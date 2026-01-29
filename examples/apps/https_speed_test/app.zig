//! HTTPS Speed Test - Platform Independent
//!
//! Tests HTTPS download speed using socket and TLS abstractions.

const std = @import("std");
const trait = @import("trait");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);
const TlsStream = platform.tls;

const BUILD_TAG = "https_speed_test_hal_v1";

/// Run HTTPS speed test with server configuration
pub fn runWithConfig(
    wifi_ssid: [:0]const u8,
    wifi_password: [:0]const u8,
    server_ip: []const u8,
    server_port: u16,
    ca_cert: ?[:0]const u8,
) void {
    log.info("==========================================", .{});
    log.info("  HTTPS Speed Test - HAL Version", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    log.info("Server: {s}:{}", .{ server_ip, server_port });

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
    log.info("SSID: {s}", .{wifi_ssid});

    b.wifi.connect(wifi_ssid, wifi_password) catch |err| {
        log.err("WiFi connect failed: {}", .{err});
        return;
    };

    // Print IP address
    if (b.wifi.getIpAddress()) |ip| {
        log.info("Connected! IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
    } else {
        log.info("Connected!", .{});
    }

    // Run tests
    Board.time.sleepMs(1000);
    runHttpsTest(server_ip, server_port, "/test/10m", "HTTPS Download 10MB", ca_cert);
    Board.time.sleepMs(1000);
    runHttpsTest(server_ip, server_port, "/test/52428800", "HTTPS Download 50MB", ca_cert);

    log.info("", .{});
    log.info("=== Test Complete ===", .{});

    while (true) {
        Board.time.sleepMs(10000);
        log.info("Still running...", .{});
    }
}

fn runHttpsTest(host: []const u8, port: u16, path: []const u8, test_name: []const u8, ca_cert: ?[:0]const u8) void {
    log.info("", .{});
    log.info("--- {s} ---", .{test_name});

    const start_ms = Board.time.getTimeMs();

    // Parse IP address
    const addr = trait.socket.parseIpv4(host) orelse {
        log.err("Invalid IP address: {s}", .{host});
        return;
    };

    // Create socket
    var sock = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };

    sock.setRecvTimeout(60000);
    sock.setSendTimeout(60000);

    // Connect
    sock.connect(addr, port) catch |err| {
        log.err("Connect failed: {}", .{err});
        sock.close();
        return;
    };

    // Initialize TLS
    var tls = TlsStream.init(sock, .{
        .ca_cert = ca_cert,
        .skip_cert_verify = ca_cert == null,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        sock.close();
        return;
    };

    // TLS handshake
    tls.handshake(host) catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls.deinit();
        return;
    };

    log.info("TLS handshake complete", .{});

    // Build HTTP request
    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch {
        log.err("Request too long", .{});
        tls.deinit();
        return;
    };

    // Send request
    var sent: usize = 0;
    while (sent < request.len) {
        const n = tls.send(request[sent..]) catch |err| {
            log.err("TLS send failed: {}", .{err});
            tls.deinit();
            return;
        };
        if (n == 0) {
            log.err("TLS send returned 0", .{});
            tls.deinit();
            return;
        }
        sent += n;
    }

    // Receive response
    var total_bytes: usize = 0;
    var last_print: usize = 0;
    var recv_buf: [16384]u8 = undefined;
    var header_done = false;

    while (true) {
        const n = tls.recv(&recv_buf) catch |err| {
            if (err == error.ConnectionClosed) break;
            log.err("TLS recv error: {}", .{err});
            break;
        };
        if (n == 0) break;

        if (!header_done) {
            // Skip HTTP header
            if (std.mem.indexOf(u8, recv_buf[0..n], "\r\n\r\n")) |pos| {
                total_bytes += n - (pos + 4);
                header_done = true;
            }
        } else {
            total_bytes += n;
        }

        // Progress every 1MB
        if (total_bytes - last_print >= 1024 * 1024) {
            const elapsed_ms = Board.time.getTimeMs() - start_ms;
            const speed = if (elapsed_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / elapsed_ms)) else 0;
            log.info("Progress: {} bytes ({} KB/s)", .{ total_bytes, speed });
            last_print = total_bytes;
        }
    }

    tls.deinit();

    const end_ms = Board.time.getTimeMs();
    const duration_ms = end_ms - start_ms;
    const speed = if (duration_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / duration_ms)) else 0;

    log.info("Downloaded: {} bytes in {} ms", .{ total_bytes, duration_ms });
    log.info("Speed: {} KB/s", .{speed});
}
