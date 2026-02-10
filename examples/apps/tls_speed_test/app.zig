//! TLS Speed Test - Echo Mode Throughput Measurement
//!
//! Tests TLS throughput using echo server:
//! - Performs TLS handshake
//! - Sends large data blocks, server echoes back
//! - Measures throughput
//!
//! Run echo_server on PC first:
//!   cd tools/echo_server && go run main.go -tls-port 8443

const std = @import("std");
const trait = @import("trait");
const tls = @import("tls");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);

const Crypto = Board.crypto;
const TlsClient = tls.Client(Board.socket, Crypto);

const TestConfig = struct {
    server_ip: [4]u8,
    port: u16,
    total_bytes: usize = 512 * 1024,
    chunk_size: usize = 8 * 1024,
    rounds: usize = 3,
};

fn parsePort(s: []const u8) ?u16 {
    return std.fmt.parseInt(u16, s, 10) catch null;
}

fn parseIp(s: []const u8) ?[4]u8 {
    var r: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, s, '.');
    for (&r) |*o| {
        const os = it.next() orelse return null;
        o.* = std.fmt.parseInt(u8, os, 10) catch return null;
    }
    if (it.next() != null) return null;
    return r;
}

const AppState = enum { connecting, connected, running_tests, done };

fn runSpeedTest(config: TestConfig, round: usize) ?u64 {
    log.info("=== Round {}/{} ===", .{ round + 1, config.rounds });

    var sock = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return null;
    };

    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    sock.connect(config.server_ip, config.port) catch |err| {
        log.err("Connect failed: {}", .{err});
        sock.close();
        return null;
    };
    log.info("TCP connected", .{});

    log.info("TLS handshake...", .{});
    const hs_start = Board.time.getTimeMs();

    var tls_buf: [32768]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tls_buf);

    var tls_client = TlsClient.init(&sock, .{
        .allocator = fba.allocator(),
        .hostname = "localhost",
        .skip_verify = true,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        sock.close();
        return null;
    };

    tls_client.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls_client.deinit();
        return null;
    };

    const hs_ms = Board.time.getTimeMs() - hs_start;
    log.info("TLS handshake: {} ms", .{hs_ms});

    var send_buf: [8 * 1024]u8 = undefined;
    for (&send_buf, 0..) |*b, i| b.* = @truncate(i);

    var recv_buf: [8 * 1024]u8 = undefined;
    var total_sent: usize = 0;
    var total_recv: usize = 0;
    const start_ms = Board.time.getTimeMs();

    while (total_sent < config.total_bytes) {
        const to_send = @min(config.chunk_size, config.total_bytes - total_sent);
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

        var recv_chunk: usize = 0;
        while (recv_chunk < sent) {
            const n = tls_client.recv(&recv_buf) catch |err| {
                log.err("TLS recv failed: {}", .{err});
                tls_client.deinit();
                return null;
            };
            recv_chunk += n;
            total_recv += n;
        }

        if (total_sent % (128 * 1024) == 0) {
            const elapsed = Board.time.getTimeMs() - start_ms;
            const speed = if (elapsed > 0) @as(u32, @intCast(@as(u64, total_sent + total_recv) * 1000 / elapsed / 1024)) else 0;
            log.info("Progress: {} KB sent, {} KB recv ({} KB/s)", .{ total_sent / 1024, total_recv / 1024, speed });
        }
    }

    const elapsed_ms = Board.time.getTimeMs() - start_ms;
    tls_client.deinit();

    const total_bytes = total_sent + total_recv;
    const speed_kbps = if (elapsed_ms > 0) @as(u32, @intCast(@as(u64, total_bytes) * 1000 / elapsed_ms / 1024)) else 0;
    log.info("Round {}: handshake {} ms, transfer {} ms, {} KB/s", .{ round + 1, hs_ms, elapsed_ms, speed_kbps });
    return elapsed_ms;
}

pub fn run(env: anytype) void {
    log.info("==========================================", .{});
    log.info("  TLS Speed Test - Echo Mode", .{});
    log.info("==========================================", .{});

    const server_ip = parseIp(env.test_server) orelse {
        log.err("Invalid TEST_SERVER: {s}", .{env.test_server});
        return;
    };
    const port = parsePort(env.tls_port) orelse {
        log.err("Invalid TLS_PORT: {s}", .{env.tls_port});
        return;
    };

    const config = TestConfig{ .server_ip = server_ip, .port = port };

    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    b.wifi.connect(env.wifi_ssid, env.wifi_password);
    var state: AppState = .connecting;

    while (Board.isRunning()) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |we| switch (we) {
                    .connected => log.info("WiFi connected", .{}),
                    .disconnected => |r| { log.warn("WiFi disconnected: {}", .{r}); state = .connecting; },
                    .connection_failed => |r| { log.err("WiFi failed: {}", .{r}); return; },
                    else => {},
                },
                .net => |ne| switch (ne) {
                    .dhcp_bound, .dhcp_renewed => |info| {
                        log.info("Got IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        state = .connected;
                    },
                    .ip_lost => { state = .connecting; },
                    else => {},
                },
                else => {},
            }
        }

        switch (state) {
            .connecting => {},
            .connected => {
                Board.time.sleepMs(1000);
                var total_time: u64 = 0;
                var ok: usize = 0;
                for (0..config.rounds) |round| {
                    if (runSpeedTest(config, round)) |t| { total_time += t; ok += 1; }
                    Board.time.sleepMs(2000);
                }
                if (ok > 0) {
                    const avg = @as(u32, @intCast(@as(u64, config.total_bytes * 2) * 1000 / (total_time / ok) / 1024));
                    log.info("Average: {} KB/s ({}/{})", .{ avg, ok, config.rounds });
                }
                state = .running_tests;
            },
            .running_tests => { state = .done; },
            .done => {},
        }
        Board.time.sleepMs(10);
    }
}
