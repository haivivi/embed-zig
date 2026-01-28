//! HTTPS Speed Test - Zig std Version
//! Tests HTTPS download speed using LWIP sockets + mbedTLS

const std = @import("std");
const idf = @import("esp_idf");

const c = @cImport({
    @cInclude("sdkconfig.h");
});

pub const std_options: std.Options = .{
    .log_level = .info,
    .logFn = idf.log.stdLogFn,
};

const Socket = idf.net.socket.Socket;
const TlsStream = idf.sal.tls.TlsStream;

// Self-signed CA certificate (embedded at compile time)
const local_ca = @embedFile("local_ca.pem");

pub fn main() !void {
    std.log.info("=== HTTPS Speed Test (Zig std) ===", .{});

    const server_ip: []const u8 = std.mem.sliceTo(c.CONFIG_TEST_SERVER_IP, 0);
    const server_port: u16 = 8443;
    std.log.info("Server: {s}:{}", .{ server_ip, server_port });

    // Wait for WiFi (initialized by stub.c)
    idf.delayMs(2000);

    // Run tests
    runHttpsTest(server_ip, server_port, "/test/10m", "HTTPS Download 10MB");
    idf.delayMs(1000);
    runHttpsTest(server_ip, server_port, "/test/52428800", "HTTPS Download 50MB");

    std.log.info("=== Test Complete ===", .{});
}

fn runHttpsTest(host: []const u8, port: u16, path: []const u8, test_name: []const u8) void {
    std.log.info("--- {s} ---", .{test_name});

    const start_ms = idf.sal.time.nowMs();

    // Parse IP address directly (no DNS needed for IP literals)
    const addr = idf.net.parseIpv4(host) orelse {
        std.log.err("Invalid IP address: {s}", .{host});
        return;
    };

    // Create socket
    var sock = Socket.tcp() catch |err| {
        std.log.err("Socket create failed: {}", .{err});
        return;
    };

    sock.setRecvTimeout(60000);
    sock.setSendTimeout(60000);

    // Connect
    sock.connect(addr, port) catch |err| {
        std.log.err("Connect failed: {}", .{err});
        sock.close();
        return;
    };

    // Initialize TLS with custom CA
    var tls = TlsStream.init(sock, .{
        .ca_cert = local_ca,
        .skip_cert_verify = false,
    }) catch |err| {
        std.log.err("TLS init failed: {}", .{err});
        sock.close();
        return;
    };

    // TLS handshake
    tls.handshake(host) catch |err| {
        std.log.err("TLS handshake failed: {}", .{err});
        tls.deinit();
        return;
    };

    std.log.info("TLS handshake complete", .{});

    // Build HTTP request
    var request_buf: [256]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch {
        std.log.err("Request too long", .{});
        tls.deinit();
        return;
    };

    // Send request
    var sent: usize = 0;
    while (sent < request.len) {
        const n = tls.send(request[sent..]) catch |err| {
            std.log.err("TLS send failed: {}", .{err});
            tls.deinit();
            return;
        };
        if (n == 0) {
            std.log.err("TLS send returned 0", .{});
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
            if (err == error.EndOfStream) break;
            std.log.err("TLS recv error: {}", .{err});
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
            const elapsed_ms = idf.sal.time.nowMs() - start_ms;
            const speed = if (elapsed_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / elapsed_ms)) else 0;
            std.log.info("Progress: {} bytes ({} KB/s)", .{ total_bytes, speed });
            last_print = total_bytes;
        }
    }

    tls.deinit();

    const end_ms = idf.sal.time.nowMs();
    const duration_ms = end_ms - start_ms;
    const speed = if (duration_ms > 0) @as(u32, @intCast(total_bytes / 1024 * 1000 / duration_ms)) else 0;

    std.log.info("Downloaded: {} bytes in {} ms", .{ total_bytes, duration_ms });
    std.log.info("Speed: {} KB/s", .{speed});
}
