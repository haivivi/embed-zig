//! TLS Concurrent Test — Verifies thread-safe send/recv on ESP32
//!
//! This test exercises the TLS Client's thread safety by running
//! concurrent send() and recv() from two FreeRTOS tasks.
//!
//! Setup:
//! 1. Connect WiFi
//! 2. TCP connect to example.com:443
//! 3. TLS handshake
//! 4. Spawn sender task (periodic HTTP requests via tls.send)
//! 5. Main task runs receiver (tls.recv)
//! 6. Run for 60 seconds, report stats

const std = @import("std");
const trait = @import("trait");
const tls = @import("tls");
const dns = @import("dns");

const platform = @import("platform.zig");
const Board = platform.Board;
const log = Board.log;
const Socket = trait.socket.from(Board.socket);
const Crypto = Board.crypto;
const Rt = platform.Rt;

const esp = @import("esp");
const idf = esp.idf;
const allocator = idf.heap.psram;

const TlsClient = tls.Client(Socket, Crypto, Rt);

/// Test configuration
const TEST_HOST = "example.com";
const TEST_PORT: u16 = 443;
const TEST_DURATION_S: u64 = 60;

/// Shared state between sender and receiver tasks
const SharedState = struct {
    tls_client: *TlsClient,
    running: bool,
    send_count: u32,
    send_errors: u32,
    recv_count: u32,
    recv_errors: u32,
    recv_bytes: u64,
};

/// HTTP request to send repeatedly
const HTTP_REQUEST = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: keep-alive\r\n\r\n";

/// Sender task: sends HTTP requests periodically
fn senderTask(ctx: ?*anyopaque) void {
    const state: *SharedState = @ptrCast(@alignCast(ctx));
    log.info("[SENDER] Task started", .{});

    while (state.running) {
        const sent = state.tls_client.send(HTTP_REQUEST) catch |err| {
            state.send_errors += 1;
            log.err("[SENDER] send error #{}: {}", .{ state.send_errors, err });
            if (state.send_errors > 10) {
                log.err("[SENDER] Too many errors, stopping", .{});
                state.running = false;
                break;
            }
            idf.time.sleepMs(1000);
            continue;
        };
        _ = sent;
        state.send_count += 1;

        if (state.send_count % 10 == 0) {
            log.info("[SENDER] Sent {} requests ({} errors)", .{ state.send_count, state.send_errors });
        }

        // Wait before next request (give receiver time to drain)
        idf.time.sleepMs(500);
    }

    log.info("[SENDER] Task ended. Total: {} sent, {} errors", .{ state.send_count, state.send_errors });
}

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  TLS Concurrent Send/Recv Test", .{});
    log.info("==========================================", .{});

    // Initialize board
    var b: Board = undefined;
    b.init() catch |err| {
        log.err("Board init failed: {}", .{err});
        return;
    };
    defer b.deinit();

    // Connect WiFi
    log.info("Connecting to WiFi...", .{});
    b.wifi.connect("HAIVIVI-MFG", "!haivivi");

    var got_ip = false;
    while (Board.isRunning() and !got_ip) {
        while (b.nextEvent()) |event| {
            switch (event) {
                .wifi => |we| switch (we) {
                    .connected => log.info("WiFi associated", .{}),
                    .disconnected => |reason| {
                        log.warn("WiFi disconnected: {}", .{reason});
                        return;
                    },
                    .connection_failed => |reason| {
                        log.err("WiFi failed: {}", .{reason});
                        return;
                    },
                    else => {},
                },
                .net => |ne| switch (ne) {
                    .dhcp_bound => |info| {
                        log.info("Got IP: {}.{}.{}.{}", .{ info.ip[0], info.ip[1], info.ip[2], info.ip[3] });
                        got_ip = true;
                    },
                    else => {},
                },
                else => {},
            }
        }
        Board.time.sleepMs(10);
    }
    if (!got_ip) return;
    Board.time.sleepMs(1000);

    // DNS resolve
    log.info("Resolving " ++ TEST_HOST ++ "...", .{});
    var resolver = dns.Resolver(Socket){
        .server = .{ 223, 5, 5, 5 },
        .protocol = .udp,
        .timeout_ms = 5000,
    };
    const ip = resolver.resolve(TEST_HOST) catch |err| {
        log.err("DNS resolve failed: {}", .{err});
        return;
    };
    log.info("Resolved: {}.{}.{}.{}", .{ ip[0], ip[1], ip[2], ip[3] });

    // TCP connect
    log.info("TCP connecting to {}.{}.{}.{}:{}", .{ ip[0], ip[1], ip[2], ip[3], TEST_PORT });
    var sock = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return;
    };
    defer sock.close();

    sock.setRecvTimeout(10000);
    sock.setSendTimeout(10000);

    sock.connect(ip, TEST_PORT) catch |err| {
        log.err("TCP connect failed: {}", .{err});
        return;
    };
    log.info("TCP connected", .{});

    // TLS handshake
    log.info("TLS handshake...", .{});
    var tls_client = TlsClient.init(&sock, .{
        .allocator = allocator,
        .hostname = TEST_HOST,
        .skip_verify = true,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        return;
    };
    defer tls_client.deinit();

    tls_client.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        return;
    };
    log.info("TLS handshake OK!", .{});

    // Setup shared state
    var state = SharedState{
        .tls_client = &tls_client,
        .running = true,
        .send_count = 0,
        .send_errors = 0,
        .recv_count = 0,
        .recv_errors = 0,
        .recv_bytes = 0,
    };

    // Spawn sender task (FreeRTOS task)
    log.info("Spawning sender task...", .{});
    idf.runtime.spawn("tls_sender", senderTask, @ptrCast(&state), .{
        .stack_size = 16384,
    }) catch |err| {
        log.err("Spawn sender failed: {}", .{err});
        return;
    };

    // Receiver loop (main task)
    log.info("Starting receiver loop for {}s...", .{TEST_DURATION_S});
    const start_ms = idf.time.nowMs();
    var recv_buf: [4096]u8 = undefined;

    while (state.running) {
        const elapsed_s = (idf.time.nowMs() - start_ms) / 1000;
        if (elapsed_s >= TEST_DURATION_S) {
            log.info("Test duration reached ({}s)", .{elapsed_s});
            state.running = false;
            break;
        }

        const n = tls_client.recv(&recv_buf) catch |err| {
            state.recv_errors += 1;
            log.err("[RECV] recv error #{}: {}", .{ state.recv_errors, err });
            if (state.recv_errors > 10) {
                log.err("[RECV] Too many errors, stopping", .{});
                state.running = false;
                break;
            }
            idf.time.sleepMs(100);
            continue;
        };
        if (n == 0) {
            log.info("[RECV] Connection closed by peer", .{});
            state.running = false;
            break;
        }
        state.recv_count += 1;
        state.recv_bytes += n;

        if (state.recv_count % 20 == 0) {
            log.info("[RECV] {} recvs, {} bytes total ({} errors)", .{
                state.recv_count, state.recv_bytes, state.recv_errors,
            });
        }
    }

    // Wait for sender to finish
    idf.time.sleepMs(2000);

    // Report
    const elapsed_s = (idf.time.nowMs() - start_ms) / 1000;
    log.info("==========================================", .{});
    log.info("  TLS Concurrent Test Results", .{});
    log.info("==========================================", .{});
    log.info("Duration: {}s", .{elapsed_s});
    log.info("Send: {} requests, {} errors", .{ state.send_count, state.send_errors });
    log.info("Recv: {} calls, {} bytes, {} errors", .{ state.recv_count, state.recv_bytes, state.recv_errors });

    if (state.send_errors == 0 and state.recv_errors == 0 and state.send_count > 0 and state.recv_count > 0) {
        log.info("[PASS] Concurrent TLS send/recv OK!", .{});
    } else if (state.send_errors > 0 or state.recv_errors > 0) {
        log.err("[FAIL] Errors detected during concurrent operation", .{});
    } else {
        log.warn("[WARN] No data transferred", .{});
    }

    log.info("==========================================", .{});

    // Keep alive
    while (Board.isRunning()) {
        Board.time.sleepMs(5000);
        log.info("Still alive... uptime={}ms", .{b.uptime()});
    }
}
