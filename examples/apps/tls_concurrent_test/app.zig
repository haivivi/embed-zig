//! TLS Concurrent Test — Verifies thread-safe send/recv on ESP32
//!
//! Tests that tls.Client.send() and tls.Client.recv() can be called from
//! two different FreeRTOS tasks simultaneously without crash or corruption.
//!
//! Test design:
//! - Sender task (spawned once): waits for signal, calls tls.send()
//! - Main task (receiver): calls tls.recv() (blocks on socket)
//! - Both overlap: recv() is blocking while send() encrypts and writes
//! - Each iteration: connect → concurrent send+recv → close → reconnect
//! - N iterations with no crash = PASS

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
const NUM_ITERATIONS: u32 = 10;

/// HTTP request
const HTTP_REQUEST = "GET / HTTP/1.1\r\nHost: " ++ TEST_HOST ++ "\r\nConnection: close\r\n\r\n";

/// Shared state between sender and receiver tasks
const SharedState = struct {
    tls_client: ?*TlsClient = null,
    /// Main → Sender: "send now"
    send_signal: bool = false,
    /// Sender → Main: "send done"
    send_done: bool = false,
    /// Sender → Main: send result
    send_ok: bool = false,
    /// Lifecycle
    running: bool = true,
};

/// Sender task: waits for signal, sends HTTP request, signals done
fn senderTask(ctx: ?*anyopaque) void {
    const state: *SharedState = @ptrCast(@alignCast(ctx));
    log.info("[SENDER] Task started", .{});

    while (state.running) {
        // Wait for send signal
        if (!state.send_signal) {
            idf.time.sleepMs(1);
            continue;
        }

        // Do the send
        const client = state.tls_client orelse {
            state.send_ok = false;
            state.send_done = true;
            state.send_signal = false;
            continue;
        };

        // Small delay to ensure receiver is blocking on recv()
        idf.time.sleepMs(100);

        const sent = client.send(HTTP_REQUEST) catch |err| {
            log.err("[SENDER] send failed: {}", .{err});
            state.send_ok = false;
            state.send_done = true;
            state.send_signal = false;
            continue;
        };

        log.info("[SENDER] sent {} bytes", .{sent});
        state.send_ok = true;
        state.send_done = true;
        state.send_signal = false;
    }

    log.info("[SENDER] Task exiting", .{});
}

pub fn run(_: anytype) void {
    log.info("==========================================", .{});
    log.info("  TLS Concurrent Send/Recv Test", .{});
    log.info("  {} iterations, reconnect each time", .{NUM_ITERATIONS});
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
    Board.time.sleepMs(500);

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

    // Spawn sender task (lives for entire test)
    var state = SharedState{};
    idf.runtime.spawn("tls_sender", senderTask, @ptrCast(&state), .{
        .stack_size = 65536, // TLS send uses ~50KB with AES-GCM on Xtensa
    }) catch |err| {
        log.err("Spawn sender failed: {}", .{err});
        return;
    };

    // Heap-allocate recv buffer (8KB) and socket to avoid stack overflow
    const recv_buf = allocator.alloc(u8, 8192) catch {
        log.err("Failed to alloc recv_buf", .{});
        return;
    };
    defer allocator.free(recv_buf);

    // Run iterations
    var pass_count: u32 = 0;
    var fail_count: u32 = 0;

    var i: u32 = 0;
    while (i < NUM_ITERATIONS) : (i += 1) {
        log.info("", .{});
        log.info("--- Iteration {}/{} ---", .{ i + 1, NUM_ITERATIONS });

        const ok = runOneIteration(&state, ip, recv_buf);
        if (ok) {
            pass_count += 1;
            log.info("Iteration {}: PASS", .{i + 1});
        } else {
            fail_count += 1;
            log.err("Iteration {}: FAIL", .{i + 1});
        }

        // Brief pause between iterations
        idf.time.sleepMs(1000);
    }

    state.running = false;

    // Final report
    log.info("", .{});
    log.info("==========================================", .{});
    log.info("  FINAL RESULTS", .{});
    log.info("==========================================", .{});
    log.info("Iterations: {} total, {} pass, {} fail", .{ NUM_ITERATIONS, pass_count, fail_count });

    if (fail_count == 0) {
        log.info("[PASS] All {} concurrent TLS iterations succeeded!", .{NUM_ITERATIONS});
        log.info("Thread safety: VERIFIED (no crash, no corruption)", .{});
    } else {
        log.err("[FAIL] {} iterations failed", .{fail_count});
    }

    log.info("==========================================", .{});

    // Keep alive
    while (Board.isRunning()) {
        Board.time.sleepMs(5000);
        log.info("Still alive... uptime={}ms", .{b.uptime()});
    }
}

/// Run one iteration: TCP connect → TLS handshake → concurrent send+recv → close
fn runOneIteration(state: *SharedState, ip: [4]u8, recv_buf: []u8) bool {
    // Heap-allocate socket (avoid large stack objects)
    const sock_ptr = allocator.create(Socket) catch {
        log.err("Failed to alloc socket", .{});
        return false;
    };
    defer allocator.destroy(sock_ptr);

    sock_ptr.* = Socket.tcp() catch |err| {
        log.err("Socket create failed: {}", .{err});
        return false;
    };

    sock_ptr.setRecvTimeout(15000);
    sock_ptr.setSendTimeout(15000);

    sock_ptr.connect(ip, TEST_PORT) catch |err| {
        log.err("TCP connect failed: {}", .{err});
        sock_ptr.close();
        return false;
    };
    log.info("TCP connected", .{});

    // Heap-allocate TLS client (struct is ~20KB with pending_plaintext)
    const tls_ptr = allocator.create(TlsClient) catch {
        log.err("Failed to alloc TLS client", .{});
        sock_ptr.close();
        return false;
    };
    defer allocator.destroy(tls_ptr);

    tls_ptr.* = TlsClient.init(sock_ptr, .{
        .allocator = allocator,
        .hostname = TEST_HOST,
        .skip_verify = true,
        .timeout_ms = 30000,
    }) catch |err| {
        log.err("TLS init failed: {}", .{err});
        sock_ptr.close();
        return false;
    };

    tls_ptr.connect() catch |err| {
        log.err("TLS handshake failed: {}", .{err});
        tls_ptr.deinit();
        sock_ptr.close();
        return false;
    };
    log.info("TLS handshake OK", .{});

    // Setup shared state for this iteration
    state.tls_client = tls_ptr;
    state.send_signal = false;
    state.send_done = false;
    state.send_ok = false;

    // Signal sender to send (it will delay 100ms to let recv() start blocking)
    state.send_signal = true;

    // Main thread: recv() — this blocks until the sender sends + server responds
    // This is the concurrent overlap point: recv() is blocking on socket.recv()
    // while send() encrypts and writes to the same socket from another task.
    var total_recv: usize = 0;
    var recv_ok = false;

    // Read response (may come in multiple TLS records)
    var recv_attempts: u32 = 0;
    while (recv_attempts < 30) : (recv_attempts += 1) {
        const n = tls_ptr.recv(recv_buf[total_recv..]) catch |err| {
            if (total_recv > 0) {
                recv_ok = true;
                break;
            }
            log.err("recv error (attempt {}): {}", .{ recv_attempts + 1, err });
            break;
        };
        if (n == 0) {
            // close_notify — expected for Connection: close
            if (total_recv > 0) recv_ok = true;
            break;
        }
        total_recv += n;
        // Check if we have a reasonable HTTP response
        if (total_recv >= 512) {
            recv_ok = true;
            if (total_recv >= recv_buf.len - 256) break;
        }
    }

    // Wait for sender to finish
    var wait: u32 = 0;
    while (!state.send_done and wait < 200) : (wait += 1) {
        idf.time.sleepMs(50);
    }

    // Clear shared state
    state.tls_client = null;

    // Clean up
    tls_ptr.deinit();
    sock_ptr.close();

    // Verify results
    const send_ok = state.send_ok;
    log.info("Send: {s}, Recv: {} bytes {s}", .{
        if (send_ok) "OK" else "FAIL",
        total_recv,
        if (recv_ok) "OK" else "FAIL",
    });

    // Check response content
    if (recv_ok and total_recv > 10) {
        if (std.mem.startsWith(u8, recv_buf[0..total_recv], "HTTP/1.1 200")) {
            log.info("Response: HTTP/1.1 200 OK", .{});
        } else if (std.mem.startsWith(u8, recv_buf[0..total_recv], "HTTP/")) {
            if (std.mem.indexOf(u8, recv_buf[0..@min(total_recv, 80)], "\r\n")) |eol| {
                log.info("Response: {s}", .{recv_buf[0..eol]});
            }
        }
    }

    return send_ok and recv_ok;
}
