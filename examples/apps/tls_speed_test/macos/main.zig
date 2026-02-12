//! TLS Speed Test for macOS - Echo Mode Throughput Measurement
//!
//! Tests TLS throughput using echo server:
//! - Performs TLS handshake
//! - Sends large data blocks to server
//! - Server echoes back the same data
//! - Measures total throughput (send + receive)
//!
//! Run echo_server on same machine or LAN:
//!   cd tools/echo_server && go run main.go -tls-port 8443
//!
//! Then run this test:
//!   cd examples/apps/tls_speed_test/macos && zig build run -- 127.0.0.1

const std = @import("std");
const std_impl = @import("std_impl");
const crypto = @import("crypto");
const tls = @import("net/tls");

const Socket = std_impl.Socket;
const Crypto = crypto; // Use lib/crypto's std.crypto-based suite
const Rt = std_impl.runtime;
const impl_time = std_impl.time;

/// TLS Client type using pure Zig TLS implementation with std.crypto
const TlsClient = tls.Client(Socket, Crypto, Rt);

/// Test configuration
const TestConfig = struct {
    server_ip: [4]u8,
    port: u16 = 8443,
    total_bytes: usize = 1024 * 1024, // 1MB per round (can do more on native)
    chunk_size: usize = 16 * 1024, // 16KB chunks
    rounds: usize = 3, // Number of test rounds
};

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

/// Run a single TLS speed test round
fn runSpeedTest(allocator: std.mem.Allocator, config: TestConfig, round: usize) ?u64 {
    std.debug.print("\n", .{});
    std.debug.print("=== Round {}/{} ===\n", .{ round + 1, config.rounds });

    var sock = Socket.tcp() catch |err| {
        std.debug.print("Socket create failed: {}\n", .{err});
        return null;
    };
    defer sock.close();

    // Set generous timeouts for large transfers
    sock.setRecvTimeout(30000);
    sock.setSendTimeout(30000);

    // Connect
    sock.connect(config.server_ip, config.port) catch |err| {
        std.debug.print("Connect failed: {}\n", .{err});
        return null;
    };
    std.debug.print("TCP connected to {}.{}.{}.{}:{}\n", .{
        config.server_ip[0],
        config.server_ip[1],
        config.server_ip[2],
        config.server_ip[3],
        config.port,
    });

    // TLS handshake
    std.debug.print("TLS handshake...\n", .{});
    const handshake_start = impl_time.nowMs();

    var tls_client = TlsClient.init(&sock, .{
        .allocator = allocator,
        .hostname = "localhost",
        .skip_verify = true, // Self-signed cert
        .timeout_ms = 30000,
    }) catch |err| {
        std.debug.print("TLS init failed: {}\n", .{err});
        return null;
    };

    tls_client.connect() catch |err| {
        std.debug.print("TLS handshake failed: {}\n", .{err});
        tls_client.deinit();
        return null;
    };

    const handshake_time = impl_time.nowMs() - handshake_start;
    std.debug.print("TLS handshake complete ({} ms)\n", .{handshake_time});

    // Prepare send buffer with pattern data
    var send_buf: [16 * 1024]u8 = undefined;
    for (&send_buf, 0..) |*b, i| {
        b.* = @truncate(i);
    }

    var recv_buf: [16 * 1024]u8 = undefined;
    var total_sent: usize = 0;
    var total_recv: usize = 0;

    const start_ms = impl_time.nowMs();

    // Send and receive in chunks
    while (total_sent < config.total_bytes) {
        const to_send = @min(config.chunk_size, config.total_bytes - total_sent);

        // Send chunk
        var sent: usize = 0;
        while (sent < to_send) {
            const n = tls_client.send(send_buf[sent..to_send]) catch |err| {
                std.debug.print("TLS send failed: {}\n", .{err});
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
                std.debug.print("TLS recv failed after {} bytes: {}\n", .{ total_recv, err });
                tls_client.deinit();
                return null;
            };
            recv_for_chunk += n;
            total_recv += n;
        }

        // Progress every 256KB
        if (total_sent % (256 * 1024) == 0) {
            const elapsed = impl_time.nowMs() - start_ms;
            const speed = if (elapsed > 0) @as(u32, @intCast(@as(u64, total_sent + total_recv) * 1000 / elapsed / 1024)) else 0;
            std.debug.print("Progress: {} KB sent, {} KB recv ({} KB/s)\n", .{
                total_sent / 1024,
                total_recv / 1024,
                speed,
            });
        }
    }

    const end_ms = impl_time.nowMs();
    const elapsed_ms = end_ms - start_ms;

    // Cleanup
    tls_client.deinit();

    // Calculate throughput
    const total_bytes = total_sent + total_recv;
    const speed_kbps = if (elapsed_ms > 0) @as(u32, @intCast(@as(u64, total_bytes) * 1000 / elapsed_ms / 1024)) else 0;

    std.debug.print("\n", .{});
    std.debug.print("Round {} Results:\n", .{round + 1});
    std.debug.print("  Handshake: {} ms\n", .{handshake_time});
    std.debug.print("  Sent: {} bytes, Received: {} bytes\n", .{ total_sent, total_recv });
    std.debug.print("  Data transfer time: {} ms\n", .{elapsed_ms});
    std.debug.print("  Throughput: {} KB/s ({} Kbps)\n", .{ speed_kbps, speed_kbps * 8 });

    return elapsed_ms;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("==========================================\n", .{});
    std.debug.print("  TLS Speed Test (macOS) - Echo Mode\n", .{});
    std.debug.print("==========================================\n", .{});

    // Get server IP and port from command line
    var args = std.process.args();
    _ = args.skip(); // Skip program name

    const ip_arg = args.next() orelse {
        std.debug.print("Usage: tls_speed_test <server_ip> [port]\n", .{});
        std.debug.print("Example: tls_speed_test 127.0.0.1 11301\n", .{});
        std.debug.print("\nMake sure echo_server is running:\n", .{});
        std.debug.print("  cd tools/echo_server && go run main.go -tls-port 11301\n", .{});
        return;
    };

    const server_ip = parseIp(ip_arg) orelse {
        std.debug.print("Invalid server IP: {s}\n", .{ip_arg});
        return;
    };

    // Optional port argument (default 8443)
    const port: u16 = if (args.next()) |port_arg|
        std.fmt.parseInt(u16, port_arg, 10) catch 8443
    else
        8443;

    const config = TestConfig{
        .server_ip = server_ip,
        .port = port,
    };

    std.debug.print("Server: {}.{}.{}.{}:{}\n", .{
        server_ip[0],
        server_ip[1],
        server_ip[2],
        server_ip[3],
        config.port,
    });
    std.debug.print("Test size: {} KB per round\n", .{config.total_bytes / 1024});
    std.debug.print("Chunk size: {} KB\n", .{config.chunk_size / 1024});
    std.debug.print("Rounds: {}\n", .{config.rounds});

    std.debug.print("\n", .{});
    std.debug.print("========================================\n", .{});
    std.debug.print("  Starting TLS Speed Test\n", .{});
    std.debug.print("========================================\n", .{});

    var total_time: u64 = 0;
    var successful_rounds: usize = 0;

    for (0..config.rounds) |round| {
        if (runSpeedTest(allocator, config, round)) |elapsed| {
            total_time += elapsed;
            successful_rounds += 1;
        }
        impl_time.sleepMs(1000); // Pause between rounds
    }

    // Summary
    std.debug.print("\n", .{});
    std.debug.print("==========================================\n", .{});
    std.debug.print("  TLS Speed Test Summary\n", .{});
    std.debug.print("==========================================\n", .{});

    if (successful_rounds > 0) {
        const avg_time = total_time / successful_rounds;
        const total_bytes_per_round = config.total_bytes * 2; // send + recv
        const avg_speed = @as(u32, @intCast(@as(u64, total_bytes_per_round) * 1000 / avg_time / 1024));
        std.debug.print("Successful rounds: {}/{}\n", .{ successful_rounds, config.rounds });
        std.debug.print("Average data transfer time: {} ms\n", .{avg_time});
        std.debug.print("Average throughput: {} KB/s ({} Kbps)\n", .{ avg_speed, avg_speed * 8 });
    } else {
        std.debug.print("All rounds failed!\n", .{});
    }
}
