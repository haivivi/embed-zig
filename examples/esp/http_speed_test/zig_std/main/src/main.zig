//! HTTP Speed Test - Using lib/http with mbedTLS + DNS support
//!
//! This example demonstrates HTTP/HTTPS client using:
//! - lib/http for HTTP protocol handling
//! - lib/dns for DNS resolution
//! - esp.sal.tls (mbedTLS) for HTTPS
//! - idf.net.Socket as the socket implementation
//! - Task with PSRAM stack for large buffers

const std = @import("std");

const idf = @import("esp");
const http = @import("http");
const dns = @import("dns");

// sdkconfig for WiFi credentials only
const c = @cImport({
    @cInclude("sdkconfig.h");
});

const BUILD_TAG = "http_speed_zig_std_v8"; // v8: DNS resolver support

pub const std_options: std.Options = .{
    .logFn = idf.log.stdLogFn,
};

// =============================================================================
// Types
// =============================================================================

/// Socket type for lib/http
const Socket = idf.net.Socket;

/// TLS Stream from sal (mbedTLS implementation)
const TlsStream = idf.sal.tls.TlsStream;

/// DNS Resolver type
const DnsResolverImpl = dns.Resolver(Socket);

/// DNS Resolver adapter - wraps lib/dns to match http.Resolver interface
const DnsAdapter = struct {
    inner: *DnsResolverImpl,

    /// Resolve hostname to IPv4 address (returns null on failure)
    pub fn resolve(self: *DnsAdapter, host: []const u8) ?[4]u8 {
        return self.inner.resolve(host) catch |err| {
            std.log.warn("DNS resolve failed for {s}: {}", .{ host, err });
            return null;
        };
    }
};

/// Full-featured HTTP Client (HTTP + HTTPS + DNS)
const FullHttpClient = http.ClientFull(Socket, TlsStream, DnsAdapter);

pub const HttpResult = struct {
    status_code: u16,
    content_length: ?usize,
    bytes_received: usize,
    duration_ms: u32,

    pub fn speedKBps(self: HttpResult) u32 {
        if (self.duration_ms == 0) return 0;
        const bytes_u64: u64 = self.bytes_received;
        return @intCast((bytes_u64 * 1000) / 1024 / self.duration_ms);
    }
};

// =============================================================================
// Global DNS Resolver
// =============================================================================

var g_dns_resolver: DnsResolverImpl = .{
    .server = .{ 223, 5, 5, 5 }, // AliDNS
    .protocol = .udp,
    .timeout_ms = 5000,
};

var g_dns_adapter: DnsAdapter = .{
    .inner = &g_dns_resolver,
};

// =============================================================================
// HTTP/HTTPS Download using lib/http + sal.tls + DNS
// =============================================================================

/// Streaming HTTP GET for large downloads
pub fn httpGetStream(url_str: []const u8) http.ClientError!HttpResult {
    const start_time = idf.sal.time.nowUs();

    // Parse URL
    const parsed = parseUrl(url_str) orelse return error.InvalidUrl;

    if (parsed.is_https) {
        return httpsGetStream(url_str, parsed, start_time);
    }

    // Resolve host to IP (supports both IP addresses and hostnames)
    const addr = resolveHost(parsed.host) orelse {
        std.log.err("Failed to resolve host: {s}", .{parsed.host});
        return error.DnsResolveFailed;
    };

    // Create TCP socket
    var sock = Socket.tcp() catch {
        std.log.err("Failed to create socket", .{});
        return error.ConnectionFailed;
    };
    defer sock.close();

    // Configure socket options
    sock.setRecvTimeout(120000); // 120 seconds for large files
    sock.setSendTimeout(120000);
    sock.setTcpNoDelay(true);
    sock.setRecvBufferSize(65536);
    sock.setSendBufferSize(65536);

    // Connect
    sock.connect(addr, parsed.port) catch {
        std.log.err("Failed to connect", .{});
        return error.ConnectionFailed;
    };

    // Build HTTP request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: zig-http/0.1\r\nConnection: close\r\n\r\n", .{ parsed.path, parsed.host, parsed.port }) catch {
        return error.SendFailed;
    };

    // Send request
    _ = sock.send(request) catch {
        std.log.err("Failed to send request", .{});
        return error.SendFailed;
    };

    // Receive response with streaming
    return receiveHttpResponse(&sock, start_time);
}

/// Resolve host - tries IP first, then DNS
fn resolveHost(host: []const u8) ?[4]u8 {
    // First try to parse as IP address
    if (Socket.parseIpv4(host)) |addr| {
        return addr;
    }

    // Try DNS resolution
    std.log.info("Resolving DNS for {s}...", .{host});
    if (g_dns_adapter.resolve(host)) |addr| {
        std.log.info("Resolved {s} -> {}.{}.{}.{}", .{ host, addr[0], addr[1], addr[2], addr[3] });
        return addr;
    }

    return null;
}

/// Streaming HTTPS GET for large downloads (using sal.tls mbedTLS)
fn httpsGetStream(url_str: []const u8, parsed: ParsedUrl, start_time: u64) http.ClientError!HttpResult {
    _ = url_str;

    // Resolve host to IP
    const addr = resolveHost(parsed.host) orelse {
        std.log.err("Failed to resolve host: {s}", .{parsed.host});
        return error.DnsResolveFailed;
    };

    // Create TCP socket
    var sock = Socket.tcp() catch {
        std.log.err("Failed to create socket", .{});
        return error.ConnectionFailed;
    };
    errdefer sock.close();

    // Configure socket options
    sock.setRecvTimeout(120000); // 120 seconds for large files
    sock.setSendTimeout(120000);
    sock.setTcpNoDelay(true);
    sock.setRecvBufferSize(65536);
    sock.setSendBufferSize(65536);

    // Connect
    sock.connect(addr, parsed.port) catch {
        std.log.err("Failed to connect", .{});
        return error.ConnectionFailed;
    };

    // Create TLS stream using sal.tls (mbedTLS)
    std.log.info("Initializing TLS (mbedTLS)...", .{});
    var tls_stream = TlsStream.init(sock, .{
        .skip_cert_verify = false, // Use ESP cert bundle
        .timeout_ms = 120000,
    }) catch {
        std.log.err("Failed to init TLS", .{});
        sock.close();
        return error.TlsError;
    };
    defer tls_stream.deinit();

    // Perform TLS handshake
    std.log.info("Performing TLS handshake with {s}...", .{parsed.host});
    tls_stream.handshake(parsed.host) catch |err| {
        std.log.err("TLS handshake failed: {}", .{err});
        return error.TlsHandshakeFailed;
    };
    std.log.info("TLS handshake completed", .{});

    // Build HTTP request
    var request_buf: [512]u8 = undefined;
    const request = std.fmt.bufPrint(&request_buf, "GET {s} HTTP/1.1\r\nHost: {s}\r\nUser-Agent: zig-http/0.1\r\nConnection: close\r\n\r\n", .{ parsed.path, parsed.host }) catch {
        return error.SendFailed;
    };

    // Send request over TLS
    var sent: usize = 0;
    while (sent < request.len) {
        const n = tls_stream.send(request[sent..]) catch {
            std.log.err("Failed to send request", .{});
            return error.SendFailed;
        };
        sent += n;
    }

    // Receive response with streaming
    return receiveHttpsResponse(&tls_stream, start_time);
}

/// Receive HTTP response with streaming (plain socket)
fn receiveHttpResponse(sock: *Socket, start_time: u64) http.ClientError!HttpResult {
    var total_received: usize = 0;
    var last_print_bytes: usize = 0;
    var header_parsed = false;
    var status_code: u16 = 0;
    var content_length: ?usize = null;
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
                        content_length = std.fmt.parseInt(usize, value, 10) catch null;
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
            printProgress(total_received, start_time, &last_print_bytes);
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

/// Receive HTTPS response with streaming (TLS stream - mbedTLS)
fn receiveHttpsResponse(tls_stream: *TlsStream, start_time: u64) http.ClientError!HttpResult {
    var total_received: usize = 0;
    var last_print_bytes: usize = 0;
    var header_parsed = false;
    var status_code: u16 = 0;
    var content_length: ?usize = null;
    var header_end_pos: usize = 0;

    var recv_buf: [32768]u8 = undefined; // 32KB buffer (runs on PSRAM stack task)

    while (true) {
        const recv_len = tls_stream.recv(&recv_buf) catch |err| {
            if (err == error.ConnectionClosed) break;
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
                        content_length = std.fmt.parseInt(usize, value, 10) catch null;
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
            printProgress(total_received, start_time, &last_print_bytes);
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

fn printProgress(total_received: usize, start_time: u64, last_print_bytes: *usize) void {
    const now = idf.sal.time.nowUs();
    const elapsed_us = now - start_time;
    const elapsed_ms: u32 = @intCast(elapsed_us / 1000);
    const bytes_u64: u64 = total_received;
    const speed_kbps: u32 = if (elapsed_ms > 0)
        @intCast((bytes_u64 * 1000) / 1024 / elapsed_ms)
    else
        0;
    const iram_free = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);
    const psram_free = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_SPIRAM);
    const rssi = idf.wifi.getRssi();
    std.log.info("Progress: {} bytes ({} KB/s) | RSSI: {} | IRAM: {}, PSRAM: {} free", .{ total_received, speed_kbps, rssi, iram_free, psram_free });
    last_print_bytes.* = total_received;
}

/// URL parsing result (mirrors lib/http internal structure)
const ParsedUrl = struct {
    is_https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

fn parseUrl(url: []const u8) ?ParsedUrl {
    var is_https = false;
    var rest = url;

    // Parse scheme
    if (std.mem.startsWith(u8, rest, "https://")) {
        is_https = true;
        rest = rest["https://".len..];
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    }

    // Find path start
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const host_port = rest[0..path_start];
    const path = if (path_start < rest.len) rest[path_start..] else "/";

    // Parse host:port
    var host: []const u8 = undefined;
    var port: u16 = if (is_https) 443 else 80;

    if (std.mem.indexOfScalar(u8, host_port, ':')) |colon| {
        host = host_port[0..colon];
        port = std.fmt.parseInt(u16, host_port[colon + 1 ..], 10) catch return null;
    } else {
        host = host_port;
    }

    if (host.len == 0) return null;

    return ParsedUrl{
        .is_https = is_https,
        .host = host,
        .port = port,
        .path = path,
    };
}

// =============================================================================
// Memory & WiFi helpers
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

fn runSpeedTest(url: []const u8, test_name: []const u8) void {
    std.log.info("--- {s} ---", .{test_name});
    std.log.info("URL: {s}", .{url});

    const mem_before = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    const result = httpGetStream(url) catch |err| {
        std.log.err("HTTP request failed: {}", .{err});
        return;
    };

    const mem_after = idf.heap.heap_caps_get_free_size(idf.heap.MALLOC_CAP_INTERNAL);

    std.log.info("Status: {}, Content-Length: {?}", .{ result.status_code, result.content_length });
    std.log.info("Downloaded: {} bytes in {} ms", .{ result.bytes_received, result.duration_ms });
    std.log.info("Speed: {} KB/s", .{result.speedKBps()});

    const mem_used = if (mem_before > mem_after) mem_before - mem_after else 0;
    std.log.info("Memory used during download: {} bytes", .{mem_used});
}

/// HTTP speed test task function - runs on PSRAM stack
fn httpSpeedTestTaskFn(_: ?*anyopaque) callconv(.c) void {
    const server_ip: []const u8 = std.mem.sliceTo(c.CONFIG_TEST_SERVER_IP, 0);
    const server_port: u16 = c.CONFIG_TEST_SERVER_PORT;

    std.log.info("", .{});
    std.log.info("=== HTTP/HTTPS Speed Test (lib/http + mbedTLS + DNS) ===", .{});
    std.log.info("Server: {s}:{}", .{ server_ip, server_port });
    std.log.info("DNS Server: 223.5.5.5 (AliDNS)", .{});
    std.log.info("Note: Running on PSRAM stack task (32KB buffer)", .{});

    // Build URLs for HTTP tests
    var url_buf_10m: [128]u8 = undefined;
    var url_buf_50m: [128]u8 = undefined;

    const url_10m = std.fmt.bufPrint(&url_buf_10m, "http://{s}:{}/test/10m", .{ server_ip, server_port }) catch "/test/10m";
    const url_50m = std.fmt.bufPrint(&url_buf_50m, "http://{s}:{}/test/52428800", .{ server_ip, server_port }) catch "/test/50m";

    // HTTP tests (local server)
    runSpeedTest(url_10m, "HTTP Download 10MB");
    idf.delayMs(1000);
    runSpeedTest(url_50m, "HTTP Download 50MB");
    idf.delayMs(1000);

    // HTTPS test (Tsinghua Mirror Python 3.12 - 27MB) - Now with DNS!
    const https_url = "https://mirrors.tuna.tsinghua.edu.cn/python/3.12.0/Python-3.12.0.tgz";
    runSpeedTest(https_url, "HTTPS Download 27MB (Tsinghua Mirror)");

    std.log.info("", .{});
    std.log.info("=== Speed Test Complete ===", .{});
    printMemoryStats();
}

export fn app_main() void {
    std.log.info("==========================================", .{});
    std.log.info("  HTTP Speed Test - lib/http + mbedTLS", .{});
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

    // Run speed test on PSRAM stack task using SAL async
    std.log.info("Starting HTTP test on PSRAM stack task (64KB stack)...", .{});
    var wg = idf.sal.async_.WaitGroup.init(idf.heap.psram);
    defer wg.deinit();
    wg.go(idf.heap.psram, "http_test", httpSpeedTestTaskFn, null, .{
        .stack_size = 65536, // 64KB
    }) catch |err| {
        std.log.err("Failed to run HTTP test task: {}", .{err});
        return;
    };
    wg.wait();
    std.log.info("HTTP test task completed", .{});

    // Keep running
    while (true) {
        idf.delayMs(10000);
        std.log.info("Still running...", .{});
    }
}
