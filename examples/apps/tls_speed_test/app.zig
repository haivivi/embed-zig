//! TLS Speed Test - Echo Mode Throughput Measurement
//!
//! Tests TLS throughput using echo server:
//! - Performs TLS handshake
//! - Sends large data blocks to server
//! - Server echoes back the same data
//! - Measures total throughput (send + receive)
//!
//! Run echo_server on PC first:
//!   cd tools/echo_server && go run main.go -tls-port 8443

const std = @import("std");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;

const esp = @import("esp");
const idf = esp.idf;
const tls = @import("tls");

/// PSRAM allocator for TLS client
const allocator = idf.heap.psram;

/// Crypto suite from board (mbedTLS with hardware acceleration)
const Crypto = Board.crypto;

/// Runtime for TLS thread safety
const Rt = idf.runtime;

/// TLS Client type using pure Zig TLS implementation
const TlsClient = tls.Client(idf.net.socket.Socket, Crypto, Rt);

/// Test configuration
const TestConfig = struct {
    server_ip: [4]u8,
    port: u16,
    total_bytes: usize = 512 * 1024, // 512KB default (smaller for TLS overhead)
    chunk_size: usize = 8 * 1024, // 8KB chunks (smaller for TLS)
    rounds: usize = 3, // Number of test rounds
};

/// Parse port string to u16
fn parsePort(port_str: []const u8) ?u16 {
    return std.fmt.parseInt(u16, port_str, 10) catch null;
}

/// Parse IP address string to bytes
fn parseIp(ip_str: []const u8) ?[4]u8 {
    var result: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, ip_str, '.');
    for (&result) |*octet| {
        const octet_str = it.next() orelse return null;
        octet.* = std.fmt.parseInt(u8, octet_str, 10) catch return null;
    }
    if (it.next() != null) return null;
    return result;
}

/// Application state
const AppState = enum {
    connecting,
    connected,
    running_tests,
    done,
};

/// Run a single TLS speed test round
fn runSpeedTest(config: TestConfig, round: usize) ?u64 {
    log.info("", .{});
    log.info("=== Round {}/{} ===", .{ round + 1, config.rounds });

    var sock = idf.net.socket.Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return null;
    };
    defer sock.close();

    // Set generous timeouts for large transfers
    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    // Connect
    sock.connect(config.server_ip, config.port) catch |err| {
        log.err("Connect failed: {}", .{err});
        return null;
    };
    log.info("TCP connected to {}.{}.{}.{}:{}", .{
        config.server_ip[0],
        config.server_ip[1],
        config.server_ip[2],
        config.server_ip[3],
        config.port,
    });

    // TLS handshake
    log.info("TLS handshake...", .{});
    const handshake_start = Board.time.getTimeMs();

    var tls_client = TlsClient.init(&sock, .{
        .allocator = allocator,
        .hostname = "localhost",
        .skip_verify = true, // Self-signed cert
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        return null;
    };

    tls_client.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls_client.deinit();
        return null;
    };

    const handshake_time = Board.time.getTimeMs() - handshake_start;
    log.info("TLS handshake complete ({} ms)", .{handshake_time});

    // Prepare send buffer with pattern data
    var send_buf: [8 * 1024]u8 = undefined;
    for (&send_buf, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    var recv_buf: [8 * 1024]u8 = undefined;
    var total_sent: usize = 0;
    var total_recv: usize = 0;

    const start_ms = Board.time.getTimeMs();

    // Send and receive in chunks
    while (total_sent < config.total_bytes) {
        const to_send = @min(config.chunk_size, config.total_bytes - total_sent);

        // Send chunk
        var sent: usize = 0;
        while (sent < to_send) {
            const n = tls_client.send(send_buf[sent..to_send]) catch |err| {
                log.err("TLS send failed: {}", .{err});
                tls_client.deinit();
                return null;
            };
            sent += n;
        }
        total_sent += sent;

        // Receive echo (may come in multiple pieces)
        var recv_for_chunk: usize = 0;
        while (recv_for_chunk < sent) {
            const n = tls_client.recv(&recv_buf) catch |err| {
                log.err("TLS recv failed after {} bytes: {}", .{ total_recv, err });
                tls_client.deinit();
                return null;
            };
            recv_for_chunk += n;
            total_recv += n;
        }

        // Progress every 128KB
        if (total_sent % (128 * 1024) == 0) {
            const elapsed = Board.time.getTimeMs() - start_ms;
            const speed = if (elapsed > 0) @as(u32, @intCast(@as(u64, total_sent + total_recv) * 1000 / elapsed / 1024)) else 0;
            log.info("Progress: {} KB sent, {} KB recv ({} KB/s)", .{
                total_sent / 1024,
                total_recv / 1024,
                speed,
            });
        }
    }

    const end_ms = Board.time.getTimeMs();
    const elapsed_ms = end_ms - start_ms;

    // Cleanup
    tls_client.deinit();

    // Calculate throughput
    const total_bytes = total_sent + total_recv;
    const speed_kbps = if (elapsed_ms > 0) @as(u32, @intCast(@as(u64, total_bytes) * 1000 / elapsed_ms / 1024)) else 0;

    log.info("", .{});
    log.info("Round {} Results:", .{round + 1});
    log.info("  Handshake: {} ms", .{handshake_time});
    log.info("  Sent: {} bytes, Received: {} bytes", .{ total_sent, total_recv });
    log.info("  Data transfer time: {} ms", .{elapsed_ms});
    log.info("  Throughput: {} KB/s ({} Kbps)", .{ speed_kbps, speed_kbps * 8 });

    return elapsed_ms;
}

/// Run TLS speed test with env from platform
pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  TLS Speed Test - Echo Mode", .{});
    log.info("==========================================", .{});

    // Parse server IP
    const server_ip = parseIp(env.test_server) orelse {
        log.err("Invalid TEST_SERVER IP: {s}", .{env.test_server});
        log.err("Set via: --define TEST_SERVER=192.168.x.x", .{});
        return;
    };

    // Parse port
    const port = parsePort(env.tls_port) orelse {
        log.err("Invalid TLS_PORT: {s}", .{env.tls_port});
        log.err("Set via: --define TLS_PORT=11301", .{});
        return;
    };

    const config = TestConfig{
        .server_ip = server_ip,
        .port = port,
    };

    log.info("Server: {}.{}.{}.{}:{}", .{
        server_ip[0],
        server_ip[1],
        server_ip[2],
        server_ip[3],
        config.port,
    });
    log.info("Test size: {} KB per round", .{config.total_bytes / 1024});
    log.info("Chunk size: {} KB", .{config.chunk_size / 1024});
    log.info("Rounds: {}", .{config.rounds});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    // Start WiFi connection
    log.info("", .{});
    log.info("Connecting to WiFi...", .{});
    log.info("SSID: {s}", .{env.wifi_ssid});
    b.wifi.connect(env.wifi_ssid, env.wifi_password);

    var state: AppState = .connecting;

    // Event loop
    while (Board.isRunning()) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |wifi_event| {
                    switch (wifi_event) {
                        .connected => {
                            log.info("WiFi connected (waiting for IP...)", .{});
                        },
                        .disconnected => |reason| {
                            log.warn("WiFi disconnected: {}", .{reason});
                            state = .connecting;
                        },
                        .connection_failed => |reason| {
                            log.err("WiFi connection failed: {}", .{reason});
                            return;
                        },
                        else => {},
                    }
                },
                .net => |net_event| {
                    switch (net_event) {
                        .dhcp_bound, .dhcp_renewed => |info| {
                            const ip = info.ip;
                            log.info("Got IP: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });
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
                Board.time.sleepMs(1000);

                log.info("", .{});
                log.info("========================================", .{});
                log.info("  Starting TLS Speed Test", .{});
                log.info("========================================", .{});

                var total_time: u64 = 0;
                var successful_rounds: usize = 0;

                for (0..config.rounds) |round| {
                    if (runSpeedTest(config, round)) |elapsed| {
                        total_time += elapsed;
                        successful_rounds += 1;
                    }
                    Board.time.sleepMs(2000); // Longer pause between TLS rounds
                }

                // Summary
                log.info("", .{});
                log.info("==========================================", .{});
                log.info("  TLS Speed Test Summary", .{});
                log.info("==========================================", .{});

                if (successful_rounds > 0) {
                    const avg_time = total_time / successful_rounds;
                    const total_bytes_per_round = config.total_bytes * 2; // send + recv
                    const avg_speed = @as(u32, @intCast(@as(u64, total_bytes_per_round) * 1000 / avg_time / 1024));
                    log.info("Successful rounds: {}/{}", .{ successful_rounds, config.rounds });
                    log.info("Average data transfer time: {} ms", .{avg_time});
                    log.info("Average throughput: {} KB/s ({} Kbps)", .{ avg_speed, avg_speed * 8 });
                } else {
                    log.err("All rounds failed!", .{});
                }

                state = .running_tests;
            },
            .running_tests => {
                state = .done;
            },
            .done => {},
        }

        Board.time.sleepMs(10);
    }
}
