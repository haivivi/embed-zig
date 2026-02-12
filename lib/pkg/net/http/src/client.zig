//! HTTP Client
//!
//! A simple HTTP/1.1 client that works with trait.socket.
//! Supports HTTP (plain) and HTTPS (with built-in pure Zig TLS).
//! Supports DNS resolution (with built-in pure Zig DNS resolver).
//!
//! Usage examples:
//!
//!   // Full featured: HTTP + HTTPS + DNS (recommended)
//!   const Client = http.HttpClient(Socket, Crypto, Rt);
//!   var client = Client{ .allocator = allocator };
//!   const resp = try client.get("https://example.com/api", &buffer);
//!
//!   // HTTP only (IP addresses only, no TLS, no DNS)
//!   const Client = http.Client(Socket);
//!   var client = Client{};
//!   const resp = try client.get("http://192.168.1.100/api", &buffer);

const std = @import("std");

const trait = @import("trait");
const tls = @import("net/tls");
const dns = @import("net/dns");

const stream_mod = @import("stream.zig");

pub const Method = enum {
    GET,
    POST,
    PUT,
    DELETE,
    HEAD,
    OPTIONS,
    PATCH,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .GET => "GET",
            .POST => "POST",
            .PUT => "PUT",
            .DELETE => "DELETE",
            .HEAD => "HEAD",
            .OPTIONS => "OPTIONS",
            .PATCH => "PATCH",
        };
    }
};

pub const Response = struct {
    status_code: u16,
    content_length: ?usize,
    chunked: bool,
    headers_end: usize,
    body_start: usize,

    // Buffer containing response data
    buffer: []u8,
    buffer_len: usize,

    pub fn statusText(self: Response) []const u8 {
        return switch (self.status_code) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            301 => "Moved Permanently",
            302 => "Found",
            304 => "Not Modified",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            500 => "Internal Server Error",
            502 => "Bad Gateway",
            503 => "Service Unavailable",
            else => "Unknown",
        };
    }

    /// Get response body
    pub fn body(self: *const Response) []const u8 {
        if (self.body_start >= self.buffer_len) return &[_]u8{};
        return self.buffer[self.body_start..self.buffer_len];
    }

    /// Check if response is successful (2xx)
    pub fn isSuccess(self: *const Response) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }
};

pub const ClientError = error{
    InvalidUrl,
    DnsResolveFailed,
    ConnectionFailed,
    SendFailed,
    ReceiveFailed,
    Timeout,
    InvalidResponse,
    TlsError,
    TlsHandshakeFailed,
    TlsNotSupported,
    BufferTooSmall,
};

// =============================================================================
// Client Type Constructors
// =============================================================================

/// Full-featured HTTP Client with built-in TLS and DNS
///
/// - Socket: Platform socket type (e.g., idf.net.socket.Socket)
/// - Crypto: Crypto suite (must include Rng). Use crypto.Suite for pure Zig.
/// - Rt: Runtime providing Mutex (for TLS thread safety). Use std_impl.runtime or esp.idf.runtime.
///
/// Example:
///   const Client = http.HttpClient(idf.net.socket.Socket, esp.impl.crypto.Suite, Rt);
///   var client = Client{ .allocator = idf.heap.psram };
///   const resp = try client.get("https://example.com/api", &buffer);
pub fn HttpClient(comptime Socket: type, comptime Crypto: type, comptime Rt: type) type {
    return HttpClientImpl(trait.socket.from(Socket), Crypto, Rt);
}

/// HTTP Client - HTTP only, no TLS, no DNS resolver
/// Use this for simple HTTP requests to IP addresses.
pub fn Client(comptime Socket: type) type {
    return ClientImpl(trait.socket.from(Socket));
}

// =============================================================================
// HttpClient Implementation (Full-featured with built-in TLS and DNS)
// =============================================================================

fn HttpClientImpl(comptime Socket: type, comptime Crypto: type, comptime Rt: type) type {
    // Built-in TLS and DNS types
    const TlsClient = tls.Client(Socket, Crypto, Rt);
    const DnsResolver = dns.Resolver(Socket);
    // Get CaStore from Crypto if available
    const CaStore = if (@hasDecl(Crypto, "x509") and @hasDecl(Crypto.x509, "CaStore"))
        Crypto.x509.CaStore
    else
        void;

    return struct {
        /// Memory allocator (required for TLS buffers)
        allocator: std.mem.Allocator,

        /// DNS server address (default: AliDNS 223.5.5.5)
        dns_server: [4]u8 = .{ 223, 5, 5, 5 },

        /// DNS query timeout in milliseconds
        dns_timeout_ms: u32 = 5000,

        /// CA store for certificate verification.
        /// If null, certificate verification is skipped (INSECURE - for testing only).
        /// If set, certificates are verified against this store.
        ca_store: ?CaStore = null,

        /// TLS/HTTP timeout in milliseconds
        timeout_ms: u32 = 30000,

        /// User-Agent header
        user_agent: []const u8 = "zig-http/0.1",

        const Self = @This();

        /// CaStore type for certificate verification
        pub const CaStoreType = CaStore;

        /// Perform HTTP GET request
        pub fn get(self: *const Self, url: []const u8, buffer: []u8) ClientError!Response {
            return self.request(.GET, url, null, null, buffer);
        }

        /// Perform HTTP POST request
        pub fn post(self: *const Self, url: []const u8, body_data: ?[]const u8, buffer: []u8) ClientError!Response {
            return self.request(.POST, url, body_data, null, buffer);
        }

        /// Perform DNS over HTTPS POST request (RFC 8484)
        pub fn postDns(self: *const Self, url: []const u8, dns_query: []const u8, buffer: []u8) ClientError!Response {
            return self.request(.POST, url, dns_query, "application/dns-message", buffer);
        }

        /// Perform HTTP request
        pub fn request(
            self: *const Self,
            method: Method,
            url: []const u8,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            // Parse URL
            const parsed = parseUrl(url) orelse return error.InvalidUrl;

            // Resolve hostname to IP address
            const addr = self.resolveHost(parsed.host) orelse {
                return error.DnsResolveFailed;
            };

            // Create and configure socket
            var socket = Socket.tcp() catch return error.ConnectionFailed;

            socket.setRecvTimeout(self.timeout_ms);
            socket.setSendTimeout(self.timeout_ms);
            socket.setTcpNoDelay(true);

            // Connect to server
            // Note: requestHttps/requestHttp will close the socket via defer
            socket.connect(addr, parsed.port) catch {
                socket.close();
                return error.ConnectionFailed;
            };

            // For HTTPS, use TLS
            if (parsed.is_https) {
                return self.requestHttps(&socket, parsed, method, body_data, content_type, buffer);
            }

            // HTTP request (no TLS)
            return self.requestHttp(&socket, parsed, method, body_data, content_type, buffer);
        }

        /// Resolve hostname to IP address using built-in DNS resolver
        fn resolveHost(self: *const Self, host: []const u8) ?[4]u8 {
            // First try to parse as IP address
            if (trait.socket.parseIpv4(host)) |addr| {
                return addr;
            }

            // Use built-in DNS resolver
            var resolver = DnsResolver{
                .server = self.dns_server,
                .protocol = .udp,
                .timeout_ms = self.dns_timeout_ms,
            };

            return resolver.resolve(host) catch null;
        }

        /// HTTP request without TLS
        fn requestHttp(
            self: *const Self,
            socket: *Socket,
            parsed: ParsedUrl,
            method: Method,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            defer socket.close();

            // Build HTTP request
            var req_buf: [2048]u8 = undefined;
            const req_len = buildRequest(&req_buf, method, parsed.host, parsed.path, body_data, content_type, self.user_agent) catch {
                return error.BufferTooSmall;
            };

            // Send request
            _ = socket.send(req_buf[0..req_len]) catch return error.SendFailed;

            // Receive response
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = socket.recv(buffer[total_received..]) catch |err| {
                    if (err == error.Timeout and total_received > 0) break;
                    if (err == error.Closed and total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                // Check if we have complete headers and enough body
                if (findHeaderEnd(buffer[0..total_received])) |headers_end| {
                    if (parseContentLength(buffer[0..headers_end])) |content_len| {
                        const expected_total = headers_end + content_len;
                        if (total_received >= expected_total) break;
                    }
                }
            }

            return parseResponse(buffer, total_received);
        }

        /// HTTPS request with built-in TLS
        fn requestHttps(
            self: *const Self,
            socket: *Socket,
            parsed: ParsedUrl,
            method: Method,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            // Ensure socket is closed when we're done
            defer socket.close();

            // Initialize TLS client with built-in pure Zig TLS
            var tls_client = TlsClient.init(socket, .{
                .allocator = self.allocator,
                .hostname = parsed.host,
                .skip_verify = self.ca_store == null,
                .ca_store = self.ca_store,
                .timeout_ms = self.timeout_ms,
            }) catch return error.TlsError;
            defer tls_client.deinit();

            // Perform TLS handshake
            tls_client.connect() catch return error.TlsHandshakeFailed;

            // Build HTTP request
            var req_buf: [2048]u8 = undefined;
            const req_len = buildRequest(&req_buf, method, parsed.host, parsed.path, body_data, content_type, self.user_agent) catch {
                return error.BufferTooSmall;
            };

            // Send request over TLS
            _ = tls_client.send(req_buf[0..req_len]) catch return error.SendFailed;

            // Receive response over TLS
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = tls_client.recv(buffer[total_received..]) catch {
                    // TLS connection closed or timeout with partial data is OK
                    if (total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                // Check if we have complete headers and enough body
                if (findHeaderEnd(buffer[0..total_received])) |headers_end| {
                    if (parseContentLength(buffer[0..headers_end])) |content_len| {
                        const expected_total = headers_end + content_len;
                        if (total_received >= expected_total) break;
                    }
                }
            }

            return parseResponse(buffer, total_received);
        }
    };
}

// =============================================================================
// Client Implementation (HTTP only, no TLS, no DNS)
// =============================================================================

fn ClientImpl(comptime Socket: type) type {
    return struct {
        /// Connection timeout in milliseconds
        timeout_ms: u32 = 30000,

        /// User-Agent header
        user_agent: []const u8 = "zig-http/0.1",

        const Self = @This();

        /// Perform HTTP GET request
        pub fn get(self: *const Self, url: []const u8, buffer: []u8) ClientError!Response {
            return self.request(.GET, url, null, null, buffer);
        }

        /// Perform HTTP POST request
        pub fn post(self: *const Self, url: []const u8, body_data: ?[]const u8, buffer: []u8) ClientError!Response {
            return self.request(.POST, url, body_data, null, buffer);
        }

        /// Perform HTTP request (HTTP only, IP addresses only)
        pub fn request(
            self: *const Self,
            method: Method,
            url: []const u8,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            // Parse URL
            const parsed = parseUrl(url) orelse return error.InvalidUrl;

            // HTTPS not supported in this client
            if (parsed.is_https) {
                return error.TlsNotSupported;
            }

            // Parse IP address (no DNS resolution)
            const addr = trait.socket.parseIpv4(parsed.host) orelse {
                return error.DnsResolveFailed;
            };

            // Create socket
            var socket = Socket.tcp() catch return error.ConnectionFailed;
            errdefer socket.close();

            // Configure socket
            socket.setRecvTimeout(self.timeout_ms);
            socket.setSendTimeout(self.timeout_ms);
            socket.setTcpNoDelay(true);

            // Connect
            socket.connect(addr, parsed.port) catch return error.ConnectionFailed;

            // HTTP request
            return self.requestHttp(&socket, parsed, method, body_data, content_type, buffer);
        }

        /// HTTP request without TLS
        fn requestHttp(
            self: *const Self,
            socket: *Socket,
            parsed: ParsedUrl,
            method: Method,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            defer socket.close();

            // Build HTTP request
            var req_buf: [2048]u8 = undefined;
            const req_len = buildRequest(&req_buf, method, parsed.host, parsed.path, body_data, content_type, self.user_agent) catch {
                return error.BufferTooSmall;
            };

            // Send request
            _ = socket.send(req_buf[0..req_len]) catch return error.SendFailed;

            // Receive response
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = socket.recv(buffer[total_received..]) catch |err| {
                    if (err == error.Timeout and total_received > 0) break;
                    if (err == error.Closed and total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                // Check if we have complete headers and enough body
                if (findHeaderEnd(buffer[0..total_received])) |headers_end| {
                    if (parseContentLength(buffer[0..headers_end])) |content_len| {
                        const expected_total = headers_end + content_len;
                        if (total_received >= expected_total) break;
                    }
                }
            }

            return parseResponse(buffer, total_received);
        }
    };
}

// =============================================================================
// Shared Helper Functions
// =============================================================================

/// URL parsing result
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

fn buildRequest(
    buf: []u8,
    method: Method,
    host: []const u8,
    path: []const u8,
    body_data: ?[]const u8,
    content_type: ?[]const u8,
    user_agent: []const u8,
) !usize {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Request line
    try w.print("{s} {s} HTTP/1.1\r\n", .{ method.toString(), path });

    // Headers
    try w.print("Host: {s}\r\n", .{host});
    try w.print("User-Agent: {s}\r\n", .{user_agent});
    try w.writeAll("Connection: close\r\n");

    if (body_data) |data| {
        try w.print("Content-Length: {d}\r\n", .{data.len});
    }

    // Content-Type header (for DoH and other POST requests)
    if (content_type) |ct| {
        try w.print("Content-Type: {s}\r\n", .{ct});
        try w.writeAll("Accept: application/dns-message\r\n");
    }

    // End headers
    try w.writeAll("\r\n");

    // Body
    if (body_data) |data| {
        try w.writeAll(data);
    }

    return fbs.pos;
}

fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (std.mem.eql(u8, data[i .. i + 4], "\r\n\r\n")) {
            return i + 4;
        }
    }
    return null;
}

fn parseContentLength(headers: []const u8) ?usize {
    var i: usize = 0;
    while (i < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, i, "\r\n") orelse break;
        const line = headers[i..line_end];

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            return std.fmt.parseInt(usize, value, 10) catch null;
        }

        i = line_end + 2;
    }
    return null;
}

fn parseResponse(buffer: []u8, len: usize) ClientError!Response {
    if (len < 12) return error.InvalidResponse;

    // Parse status line: "HTTP/1.1 200 OK\r\n"
    if (!std.mem.startsWith(u8, buffer[0..len], "HTTP/1.")) {
        return error.InvalidResponse;
    }

    // Find status code
    const status_start = 9; // "HTTP/1.x "
    if (len < status_start + 3) return error.InvalidResponse;

    const status_code = std.fmt.parseInt(u16, buffer[status_start .. status_start + 3], 10) catch {
        return error.InvalidResponse;
    };

    // Find headers end
    const headers_end = findHeaderEnd(buffer[0..len]) orelse return error.InvalidResponse;

    // Parse Content-Length if present
    var content_length: ?usize = null;
    var chunked = false;

    // Simple header parsing
    var i: usize = 0;
    while (i < headers_end) {
        // Find line end
        const line_end = std.mem.indexOfPos(u8, buffer[0..headers_end], i, "\r\n") orelse break;
        const line = buffer[i..line_end];

        if (std.ascii.startsWithIgnoreCase(line, "content-length:")) {
            const value = std.mem.trim(u8, line["content-length:".len..], " ");
            content_length = std.fmt.parseInt(usize, value, 10) catch null;
        } else if (std.ascii.startsWithIgnoreCase(line, "transfer-encoding:")) {
            const value = std.mem.trim(u8, line["transfer-encoding:".len..], " ");
            chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
        }

        i = line_end + 2;
    }

    return Response{
        .status_code = status_code,
        .content_length = content_length,
        .chunked = chunked,
        .headers_end = headers_end,
        .body_start = headers_end,
        .buffer = buffer,
        .buffer_len = len,
    };
}

// =============================================================================
// Unit Tests
// =============================================================================

test "parseUrl - basic HTTP" {
    const result = parseUrl("http://example.com/path").?;
    try std.testing.expect(!result.is_https);
    try std.testing.expectEqualStrings("example.com", result.host);
    try std.testing.expectEqual(@as(u16, 80), result.port);
    try std.testing.expectEqualStrings("/path", result.path);
}

test "parseUrl - basic HTTPS" {
    const result = parseUrl("https://example.com/api/v1").?;
    try std.testing.expect(result.is_https);
    try std.testing.expectEqualStrings("example.com", result.host);
    try std.testing.expectEqual(@as(u16, 443), result.port);
    try std.testing.expectEqualStrings("/api/v1", result.path);
}

test "parseUrl - custom port" {
    const result = parseUrl("http://localhost:8080/test").?;
    try std.testing.expect(!result.is_https);
    try std.testing.expectEqualStrings("localhost", result.host);
    try std.testing.expectEqual(@as(u16, 8080), result.port);
    try std.testing.expectEqualStrings("/test", result.path);
}

test "parseUrl - HTTPS custom port" {
    const result = parseUrl("https://api.example.com:8443/").?;
    try std.testing.expect(result.is_https);
    try std.testing.expectEqualStrings("api.example.com", result.host);
    try std.testing.expectEqual(@as(u16, 8443), result.port);
    try std.testing.expectEqualStrings("/", result.path);
}

test "parseUrl - no path" {
    const result = parseUrl("https://example.com").?;
    try std.testing.expect(result.is_https);
    try std.testing.expectEqualStrings("example.com", result.host);
    try std.testing.expectEqualStrings("/", result.path);
}

test "parseUrl - IP address" {
    const result = parseUrl("http://192.168.1.100:3000/api").?;
    try std.testing.expectEqualStrings("192.168.1.100", result.host);
    try std.testing.expectEqual(@as(u16, 3000), result.port);
}

test "parseUrl - invalid empty host" {
    try std.testing.expect(parseUrl("http:///path") == null);
}

test "buildRequest - GET request" {
    var buf: [2048]u8 = undefined;
    const len = buildRequest(&buf, .GET, "example.com", "/api", null, null, "test-agent") catch unreachable;
    const request = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, request, "GET /api HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Host: example.com\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "User-Agent: test-agent\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Connection: close\r\n") != null);
}

test "buildRequest - POST request with body" {
    var buf: [2048]u8 = undefined;
    const body = "test body data";
    const len = buildRequest(&buf, .POST, "api.example.com", "/submit", body, "text/plain", "test-agent") catch unreachable;
    const request = buf[0..len];

    try std.testing.expect(std.mem.indexOf(u8, request, "POST /submit HTTP/1.1\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Content-Length: 14\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "Content-Type: text/plain\r\n") != null);
    try std.testing.expect(std.mem.endsWith(u8, request, "test body data"));
}

test "findHeaderEnd - valid response" {
    const response = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\nBody";
    const end = findHeaderEnd(response).?;
    try std.testing.expectEqual(@as(usize, 44), end);
    try std.testing.expectEqualStrings("Body", response[end..]);
}

test "findHeaderEnd - incomplete headers" {
    try std.testing.expect(findHeaderEnd("HTTP/1.1 200 OK\r\n") == null);
}

test "parseContentLength - found" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 1234\r\n\r\n";
    const len = parseContentLength(headers).?;
    try std.testing.expectEqual(@as(usize, 1234), len);
}

test "parseContentLength - not found" {
    const headers = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n";
    try std.testing.expect(parseContentLength(headers) == null);
}

test "parseResponse - 200 OK" {
    var buffer: [256]u8 = undefined;
    const response_text = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 13\r\n\r\nHello, World!";
    @memcpy(buffer[0..response_text.len], response_text);

    const resp = parseResponse(&buffer, response_text.len) catch unreachable;
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expectEqual(@as(usize, 13), resp.content_length.?);
    try std.testing.expect(!resp.chunked);
    try std.testing.expectEqualStrings("Hello, World!", resp.body());
}

test "parseResponse - 404 Not Found" {
    var buffer: [256]u8 = undefined;
    const response_text = "HTTP/1.1 404 Not Found\r\nContent-Length: 9\r\n\r\nNot Found";
    @memcpy(buffer[0..response_text.len], response_text);

    const resp = parseResponse(&buffer, response_text.len) catch unreachable;
    try std.testing.expectEqual(@as(u16, 404), resp.status_code);
    try std.testing.expectEqualStrings("Not Found", resp.statusText());
}

test "parseResponse - chunked transfer" {
    var buffer: [256]u8 = undefined;
    const response_text = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n";
    @memcpy(buffer[0..response_text.len], response_text);

    const resp = parseResponse(&buffer, response_text.len) catch unreachable;
    try std.testing.expectEqual(@as(u16, 200), resp.status_code);
    try std.testing.expect(resp.chunked);
    try std.testing.expect(resp.content_length == null);
}

test "Response.isSuccess" {
    var buffer: [256]u8 = undefined;

    // 200 OK
    const ok_text = "HTTP/1.1 200 OK\r\n\r\n";
    @memcpy(buffer[0..ok_text.len], ok_text);
    const ok_resp = parseResponse(&buffer, ok_text.len) catch unreachable;
    try std.testing.expect(ok_resp.isSuccess());

    // 201 Created
    const created_text = "HTTP/1.1 201 Created\r\n\r\n";
    @memcpy(buffer[0..created_text.len], created_text);
    const created_resp = parseResponse(&buffer, created_text.len) catch unreachable;
    try std.testing.expect(created_resp.isSuccess());

    // 404 Not Found
    const notfound_text = "HTTP/1.1 404 Not Found\r\n\r\n";
    @memcpy(buffer[0..notfound_text.len], notfound_text);
    const notfound_resp = parseResponse(&buffer, notfound_text.len) catch unreachable;
    try std.testing.expect(!notfound_resp.isSuccess());
}

test "Method.toString" {
    try std.testing.expectEqualStrings("GET", Method.GET.toString());
    try std.testing.expectEqualStrings("POST", Method.POST.toString());
    try std.testing.expectEqualStrings("PUT", Method.PUT.toString());
    try std.testing.expectEqualStrings("DELETE", Method.DELETE.toString());
}
