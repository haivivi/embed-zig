//! HTTP Client
//!
//! A simple HTTP/1.1 client that works with trait.socket.
//! Supports HTTP (plain) and HTTPS (with platform TLS implementation).
//! Supports DNS resolution (with user-provided resolver).
//!
//! Usage examples:
//!
//!   // HTTP only (IP addresses only)
//!   const HttpClient = http.Client(Socket);
//!
//!   // HTTP + HTTPS
//!   const HttpClient = http.ClientWithTls(Socket, TlsStream);
//!
//!   // HTTP + DNS resolver
//!   const HttpClient = http.ClientWithResolver(Socket, DnsResolver);
//!
//!   // HTTP + HTTPS + DNS resolver (full featured)
//!   const HttpClient = http.ClientFull(Socket, TlsStream, DnsResolver);
//!
//! Resolver interface:
//!   The resolver type must have a `resolve` method:
//!     fn resolve(self: *Resolver, host: []const u8) ?[4]u8

const std = @import("std");

const trait = @import("trait");

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

/// HTTP Client - HTTP only, no TLS, no DNS resolver
pub fn Client(comptime Socket: type) type {
    const socket = trait.socket.from(Socket);
    return ClientImpl(socket, void, void);
}

/// HTTP Client with TLS - supports HTTP and HTTPS, no DNS resolver
pub fn ClientWithTls(comptime Socket: type, comptime TlsStream: type) type {
    const socket = trait.socket.from(Socket);
    // TODO: trait.tls.from(TlsStream) when implemented
    return ClientImpl(socket, TlsStream, void);
}

/// HTTP Client with DNS resolver - HTTP only with DNS resolution
pub fn ClientWithResolver(comptime Socket: type, comptime Resolver: type) type {
    const socket = trait.socket.from(Socket);
    return ClientImpl(socket, void, Resolver);
}

/// Full-featured HTTP Client - HTTP, HTTPS, and DNS resolution
pub fn ClientFull(
    comptime Socket: type,
    comptime TlsStream: type,
    comptime Resolver: type,
) type {
    const socket = trait.socket.from(Socket);
    // TODO: trait.tls.from(TlsStream) when implemented
    return ClientImpl(socket, TlsStream, Resolver);
}

// =============================================================================
// Client Implementation
// =============================================================================

fn ClientImpl(
    comptime Socket: type,
    comptime TlsStreamType: type,
    comptime ResolverType: type,
) type {
    const has_tls = TlsStreamType != void;
    const has_resolver = ResolverType != void;

    return struct {
        /// Connection timeout in milliseconds
        timeout_ms: u32 = 30000,

        /// Skip TLS certificate verification (for embedded/testing)
        skip_cert_verify: bool = true,

        /// User-Agent header
        user_agent: []const u8 = "zig-http/0.1",

        /// DNS resolver (optional, set if ResolverType != void)
        resolver: if (has_resolver) *ResolverType else void = if (has_resolver) undefined else {},

        const Self = @This();
        const Stream = stream_mod.SocketStream(Socket);

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

            // Create socket
            var socket = Socket.tcp() catch return error.ConnectionFailed;
            errdefer socket.close();

            // Configure socket
            socket.setRecvTimeout(self.timeout_ms);
            socket.setSendTimeout(self.timeout_ms);
            socket.setTcpNoDelay(true);

            // Resolve host to IP
            const addr = self.resolveHost(parsed.host) orelse {
                return error.DnsResolveFailed;
            };

            // Connect
            socket.connect(addr, parsed.port) catch return error.ConnectionFailed;

            // For HTTPS, use TLS
            if (parsed.is_https) {
                if (has_tls) {
                    return self.requestHttps(socket, parsed, method, body_data, content_type, buffer);
                } else {
                    socket.close();
                    return error.TlsNotSupported;
                }
            }

            // HTTP request (no TLS)
            return self.requestHttp(socket, parsed, method, body_data, content_type, buffer);
        }

        /// Resolve hostname to IP address
        fn resolveHost(self: *const Self, host: []const u8) ?[4]u8 {
            // First try to parse as IP address
            if (Socket.parseIpv4(host)) |addr| {
                return addr;
            }

            // If resolver is available, try DNS resolution
            if (has_resolver) {
                return self.resolver.resolve(host);
            }

            // No resolver and not an IP address
            return null;
        }

        /// HTTP request without TLS
        fn requestHttp(
            self: *const Self,
            socket: Socket,
            parsed: ParsedUrl,
            method: Method,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            var sock = socket;
            defer sock.close();

            // Build HTTP request
            var req_buf: [2048]u8 = undefined;
            const req_len = buildRequest(&req_buf, method, parsed.host, parsed.path, body_data, content_type, self.user_agent) catch {
                return error.BufferTooSmall;
            };

            // Send request
            _ = sock.send(req_buf[0..req_len]) catch return error.SendFailed;

            // Receive response
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = sock.recv(buffer[total_received..]) catch |err| {
                    if (err == error.Timeout and total_received > 0) break;
                    if (err == error.Closed and total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                // Check if we have complete headers and enough body
                if (findHeaderEnd(buffer[0..total_received])) |headers_end| {
                    // Parse content-length to know when to stop
                    if (parseContentLength(buffer[0..headers_end])) |content_len| {
                        const expected_total = headers_end + content_len;
                        if (total_received >= expected_total) break;
                    }
                }
            }

            // Parse response
            return parseResponse(buffer, total_received);
        }

        /// HTTPS request with TLS
        fn requestHttps(
            self: *const Self,
            socket: Socket,
            parsed: ParsedUrl,
            method: Method,
            body_data: ?[]const u8,
            content_type: ?[]const u8,
            buffer: []u8,
        ) ClientError!Response {
            if (!has_tls) {
                return error.TlsNotSupported;
            }

            // Initialize TLS stream
            var tls_stream = TlsStreamType.init(socket, .{
                .skip_cert_verify = self.skip_cert_verify,
                .timeout_ms = self.timeout_ms,
            }) catch return error.TlsError;
            defer tls_stream.deinit();

            // Perform TLS handshake
            tls_stream.handshake(parsed.host) catch {
                return error.TlsHandshakeFailed;
            };

            // Build HTTP request
            var req_buf: [2048]u8 = undefined;
            const req_len = buildRequest(&req_buf, method, parsed.host, parsed.path, body_data, content_type, self.user_agent) catch {
                return error.BufferTooSmall;
            };

            // Send request over TLS
            var sent: usize = 0;
            while (sent < req_len) {
                const n = tls_stream.send(req_buf[sent..req_len]) catch return error.SendFailed;
                sent += n;
            }

            // Receive response over TLS
            var total_received: usize = 0;
            while (total_received < buffer.len) {
                const n = tls_stream.recv(buffer[total_received..]) catch |err| {
                    if (err == error.ConnectionClosed and total_received > 0) break;
                    if (err == error.Timeout and total_received > 0) break;
                    return error.ReceiveFailed;
                };
                if (n == 0) break;
                total_received += n;

                // Check if we have complete headers and enough body
                if (findHeaderEnd(buffer[0..total_received])) |headers_end| {
                    // Parse content-length to know when to stop
                    if (parseContentLength(buffer[0..headers_end])) |content_len| {
                        const expected_total = headers_end + content_len;
                        if (total_received >= expected_total) break;
                    }
                }
            }

            // Parse response
            return parseResponse(buffer, total_received);
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
    };
}

/// URL parsing result
const ParsedUrl = struct {
    is_https: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
};

// =============================================================================
// URL Parsing
// =============================================================================

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
