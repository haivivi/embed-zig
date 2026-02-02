//! HTTP Speed Test - Platform Independent (Event-Driven)
//!
//! Tests HTTP download speed using socket abstraction.
//! Uses event-driven WiFi connection.

const std = @import("std");
const trait = @import("trait");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);

const BUILD_TAG = "http_speed_test_hal_v2_event";

/// Application state machine
const AppState = enum {
    connecting,
    connected,
    running_tests,
    done,
};

/// Run HTTP speed test with env from platform
pub fn run(env: anytype) void {
    // Parse port from string
    const port = std.fmt.parseInt(u16, env.test_server_port, 10) catch 8080;

    log.info("==========================================", .{});
    log.info("  HTTP Speed Test - HAL Version (Event)", .{});
    log.info("  Build Tag: {s}", .{BUILD_TAG});
    log.info("==========================================", .{});

    log.info("Server: {s}:{}", .{ env.test_server_ip, port });

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
        // Poll for events
        b.poll();

        // Process events
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .connected => {
                            log.info("WiFi connected to AP", .{});
                        },
                        .got_ip => |ip| {
                            log.info("Got IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
                            state = .connected;
                        },
                        .disconnected => |reason| {
                            log.warn("WiFi disconnected: {}", .{reason});
                            state = .connecting;
                        },
                        .connection_failed => |reason| {
                            log.err("WiFi connection failed: {}", .{reason});
                            return;
                        },
                        .rssi_changed => {},
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
                runHttpTest(env.test_server_ip, port, "/test/10m", "HTTP Download 10MB");
                Board.time.sleepMs(1000);
                runHttpTest(env.test_server_ip, port, "/test/52428800", "HTTP Download 50MB");
                state = .running_tests;
            },
            .running_tests => {
                log.info("", .{});
                log.info("=== Test Complete ===", .{});
                state = .done;
            },
            .done => {
                // Idle
            },
        }

        Board.time.sleepMs(10);
    }
}

fn runHttpTest(host: []const u8, port: u16, path: []const u8, test_name: []const u8) void {
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
    defer sock.close();

    sock.setRecvTimeout(60000);
    sock.setSendTimeout(60000);

    // Connect
    sock.connect(addr, port) catch |err| {
        log.err("Connect failed: {}", .{err});
        return;
    };

    // Build HTTP request
    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch {
        log.err("Request too long", .{});
        return;
    };

    // Send request
    var sent: usize = 0;
    while (sent < request.len) {
        const n = sock.send(request[sent..]) catch |err| {
            log.err("Send failed: {}", .{err});
            return;
        };
        if (n == 0) {
            log.err("Send returned 0", .{});
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
        const n = sock.recv(&recv_buf) catch break;
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

    const end_ms = Board.time.getTimeMs();
    const duration_ms = end_ms - start_ms;
    const speed = if (duration_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / duration_ms)) else 0;

    log.info("Downloaded: {} bytes in {} ms", .{ total_bytes, duration_ms });
    log.info("Speed: {} KB/s", .{speed});
}
