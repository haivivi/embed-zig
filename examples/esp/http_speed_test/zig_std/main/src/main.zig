//! HTTP Speed Test - Zig Standard Library Version
//!
//! This example demonstrates HTTP client implementation using:
//! - idf.net.socket (Zig wrapper for LWIP sockets)
//! - Pure Zig HTTP protocol handling (no esp_http_client)
//! - Task with PSRAM stack for large buffers
//!
//! Note: This is a proof-of-concept for "hand-rolled HTTP client in Zig"
//! For production use, esp_http_client is recommended.

const std = @import("std");

const idf = @import("esp");

// sdkconfig for WiFi credentials only
const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "http_speed_zig_std_v3"; // v3: using idf.net.socket

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

// =============================================================================
// Simple HTTP Client using idf.net.socket
// =============================================================================

pub const HttpError = error{
    SocketCreateFailed,
    DnsResolveFailed,
    ConnectFailed,
    SendFailed,
    ReceiveFailed,
    InvalidResponse,
    Timeout,
};

pub const HttpResult = struct {
    status_code: u16,
    content_length: i64,
    bytes_received: usize,
    duration_ms: u32,

    pub fn speedKBps(self: HttpResult) u32 {
        if (self.duration_ms == 0) return 0;
        // Use u64 to avoid overflow: bytes * 1000 can overflow u32 when bytes > 4MB
        const bytes_u64: u64 = self.bytes_received;
        return @intCast((bytes_u64 * 1000) / 1024 / self.duration_ms);
    }
};

/// Simple HTTP GET request using idf.net.socket
/// This is a minimal implementation - no chunked transfer, no redirects
pub fn httpGet(host: []const u8, port: u16, path: []const u8) HttpError!HttpResult {
    const start_time = idf.sal.time.nowUs();

    // Parse IP address
    const addr = idf.net.socket.parseIpv4(host) orelse {
        std.log.err("Failed to parse IP address: {s}", .{host});
        return HttpError.DnsResolveFailed;
    };

    // Create TCP socket
    var sock = idf.net.Socket.tcp() catch {
        std.log.err("Failed to create socket", .{});
        return HttpError.SocketCreateFailed;
    };
    defer sock.close();

    // Configure socket options
    sock.setRecvTimeout(120000); // 120 seconds for large files
    sock.setSendTimeout(120000);
    sock.setTcpNoDelay(true);
    sock.setRecvBufferSize(65536);
    sock.setSendBufferSize(65536);

    // Connect
    sock.connect(addr, port) catch {
        std.log.err("Failed to connect", .{});
        return HttpError.ConnectFailed;
    };

    // Build HTTP request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch {
        return HttpError.SendFailed;
    };

    // Send request
    _ = sock.send(request) catch {
        std.log.err("Failed to send request", .{});
        return HttpError.SendFailed;
    };

    // Receive response
    var total_received: usize = 0;
    var last_print_bytes: usize = 0;
    var header_parsed = false;
    var status_code: u16 = 0;
    var content_length: i64 = -1;
    var header_end_pos: usize = 0;

    var recv_buf: [32768]u8 = undefined; // 32KB buffer (runs on PSRAM stack task)

    while (true) {
        const recv_len = sock.recv(&recv_buf) catch |err| {
            if (err == error.Timeout) break;
            break;
        };
        if (recv_len == 0) break;

        if (!header_parsed) {
            // Look for header end
            const data = recv_buf[0..recv_len];
            if (std.mem.indexOf(u8, data, "\r\n\r\n")) |pos| {
                header_end_pos = pos + 4;
                header_parsed = true;

                // Parse status code from first line
                if (std.mem.indexOf(u8, data[0..pos], " ")) |space1| {
                    if (std.mem.indexOfPos(u8, data[0..pos], space1 + 1, " ")) |space2| {
                        const status_str = data[space1 + 1 .. space2];
                        status_code = std.fmt.parseInt(u16, status_str, 10) catch 0;
                    }
                }

                // Parse Content-Length
                var lines = std.mem.splitSequence(u8, data[0..pos], "\r\n");
                while (lines.next()) |line| {
                    if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
                        const value = std.mem.trim(u8, line["content-length:".len..], " ");
                        content_length = std.fmt.parseInt(i64, value, 10) catch -1;
                    }
                }

                // Count body bytes in this chunk
                total_received += recv_len - header_end_pos;
            }
        } else {
            total_received += recv_len;
        }

        // Print progress every 1MB with memory stats and WiFi RSSI
        if (total_received - last_print_bytes >= 1024 * 1024) {
            const now = idf.sal.time.nowUs();
            const elapsed_us = now - start_time;
            const elapsed_ms: u32 = @intCast(elapsed_us / 1000);
            // Use u64 to avoid overflow: bytes * 1000 can overflow u32 when bytes > 4MB
            const bytes_u64: u64 = total_received;
            const speed_kbps: u32 = if (elapsed_ms > 0)
                @intCast((bytes_u64 * 1000) / 1024 / elapsed_ms)
            else
                0;
            const iram_free = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);
            const psram_free = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_SPIRAM);
            // Get WiFi RSSI via idf.wifi module
            const rssi = idf.wifi.getRssi();
            std.log.info("Progress: {} bytes ({} KB/s) | RSSI: {} | IRAM: {}, PSRAM: {} free", .{ total_received, speed_kbps, rssi, iram_free, psram_free });
            last_print_bytes = total_received;
        }
    }

    const end_time = idf.sal.time.nowUs();
    const duration_us = end_time - start_time;
    const duration_ms: u32 = @intCast(duration_us / 1000);

    return HttpResult{
        .status_code = status_code,
        .content_length = content_length,
        .bytes_received = total_received,
        .duration_ms = duration_ms,
    };
}

// =============================================================================
// Memory & WiFi helpers (reusing esp lib)
// =============================================================================

fn printMemoryStats() void {
    std.log.info("=== Heap Memory Statistics ===", .{});

    const internal = idf.heap.getInternalStats();
    std.log.info("Internal DRAM: Total={} Free={} Used={}", .{
        internal.total,
        internal.free,
        internal.used,
    });

    const psram = idf.heap.getPsramStats();
    if (psram.total > 0) {
        std.log.info("External PSRAM: Total={} Free={} Used={}", .{
            psram.total,
            psram.free,
            psram.used,
        });
    }
}

fn runSpeedTest(host: []const u8, port: u16, path: []const u8, test_name: []const u8) void {
    std.log.info("--- {s} ---", .{test_name});

    const mem_before = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    const result = httpGet(host, port, path) catch |err| {
        std.log.err("HTTP request failed: {}", .{err});
        return;
    };

    const mem_after = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    std.log.info("Status: {}, Content-Length: {}", .{ result.status_code, result.content_length });
    std.log.info("Downloaded: {} bytes in {} ms", .{ result.bytes_received, result.duration_ms });
    std.log.info("Speed: {} KB/s", .{result.speedKBps()});

    const mem_used = if (mem_before > mem_after) mem_before - mem_after else 0;
    std.log.info("Memory used during download: {} bytes", .{mem_used});
}

/// HTTP speed test task function - runs on PSRAM stack
fn httpSpeedTestTaskFn(_: ?*anyopaque) callconv(.c) c_int {
    const server_ip: []const u8 = std.mem.sliceTo(c.CONFIG_TEST_SERVER_IP, 0);
    const server_port: u16 = c.CONFIG_TEST_SERVER_PORT;

    std.log.info("", .{});
    std.log.info("=== HTTP Speed Test (Zig Std) ===", .{});
    std.log.info("Server: {s}:{}", .{ server_ip, server_port });
    std.log.info("Note: Using pure Zig HTTP client with idf.net.socket", .{});
    std.log.info("Note: Running on PSRAM stack task (32KB buffer)", .{});

    // Test 10MB and 50MB for stable speed measurement
    const tests = [_]struct { path: []const u8, name: []const u8 }{
        .{ .path = "/test/10m", .name = "Download 10MB" },
        .{ .path = "/test/52428800", .name = "Download 50MB" },
    };

    for (tests) |t| {
        runSpeedTest(server_ip, server_port, t.path, t.name);
        idf.delayMs(1000);
    }

    std.log.info("", .{});
    std.log.info("=== Speed Test Complete ===", .{});
    printMemoryStats();

    return 0;
}

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("  HTTP Speed Test - Zig Std Version", .{});
    std.log.info("  Build Tag: {s}", .{BUILD_TAG});
    std.log.info("==========================================", .{});

    printMemoryStats();

    // Initialize WiFi
    std.log.info("", .{});
    std.log.info("Initializing WiFi...", .{});

    var wifi = idf.Wifi.init() catch |err| {
        std.log.err("WiFi init failed: {}", .{err});
        return;
    };

    // Connect to WiFi (sentinel-terminated strings for C interop)
    const ssid: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_SSID));
    const password: [:0]const u8 = std.mem.span(@as([*:0]const u8, c.CONFIG_WIFI_PASSWORD));

    std.log.info("Connecting to SSID: {s}", .{ssid});

    wifi.connect(.{
        .ssid = ssid,
        .password = password,
        .timeout_ms = 30000,
    }) catch |err| {
        std.log.err("WiFi connect failed: {}", .{err});
        return;
    };

    // Print IP address
    const ip_bytes = wifi.getIpAddress();
    std.log.info("Connected! IP: {}.{}.{}.{}", .{ ip_bytes[0], ip_bytes[1], ip_bytes[2], ip_bytes[3] });

    printMemoryStats();

    // Run speed test on PSRAM stack task (allows 32KB buffer + std.log in loop)
    // Using new SAL interface with heap.psram allocator
    std.log.info("Starting HTTP test on PSRAM stack task (64KB stack)...", .{});
    const result = idf.sal.thread.go(idf.heap.psram, "http_test", httpSpeedTestTaskFn, null, .{
        .stack_size = 65536, // 64KB
    }) catch |err| {
        std.log.err("Failed to run HTTP test task: {}", .{err});
        return;
    };
    std.log.info("HTTP test task completed with result: {}", .{result});

    // Keep running
    while (true) {
        idf.delayMs(10000);
        std.log.info("Still running...", .{});
    }
}
