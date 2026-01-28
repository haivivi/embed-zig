//! Cross-Platform DNS Resolver
//!
//! Supports UDP and TCP DNS protocols.
//! DNS over HTTPS (DoH) requires platform-specific implementation
//! (e.g., esp.net.DnsResolver uses esp_http_client).
//!
//! Example:
//!   const dns = @import("dns");
//!   const esp = @import("esp");
//!
//!   // Create resolver with platform socket
//!   const Resolver = dns.Resolver(esp.trait.socket.from);
//!   var resolver = Resolver{
//!       .server = .{ 223, 5, 5, 5 },  // AliDNS
//!       .protocol = .udp,
//!   };
//!
//!   // Resolve
//!   const ip = try resolver.resolve("www.google.com");

const std = @import("std");

const trait = @import("trait");

pub const Ipv4Address = [4]u8;

pub const DnsError = error{
    InvalidHostname,
    QueryBuildFailed,
    ResponseParseFailed,
    NoAnswer,
    SocketError,
    Timeout,
    TlsError,
    HttpError,
};

pub const Protocol = enum {
    udp,
    tcp,
    https,
};

/// DNS Resolver - generic over socket type
///
/// `Socket` must implement the Socket interface (tcp/udp/send/recv/etc).
pub fn Resolver(comptime Socket: type) type {
    const socket = trait.socket.from(Socket);

    return struct {
        /// DNS server address (for UDP/TCP)
        server: Ipv4Address = .{ 8, 8, 8, 8 }, // Google DNS default

        /// Protocol to use
        protocol: Protocol = .udp,

        /// Timeout in milliseconds
        timeout_ms: u32 = 5000,

        /// DoH server host (for HTTPS protocol)
        doh_host: []const u8 = "223.5.5.5",

        const Self = @This();

        /// Resolve hostname to IPv4 address
        pub fn resolve(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            return switch (self.protocol) {
                .udp => self.resolveUdp(hostname),
                .tcp => self.resolveTcp(hostname),
                .https => self.resolveHttps(hostname),
            };
        }

        fn resolveUdp(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            var sock = socket.udp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);

            // Build query
            var query_buf: [512]u8 = undefined;
            const query_len = buildQuery(&query_buf, hostname, generateTxId()) catch return error.QueryBuildFailed;

            // Send query
            _ = sock.sendTo(self.server, 53, query_buf[0..query_len]) catch return error.SocketError;

            // Receive response
            var response_buf: [512]u8 = undefined;
            const response_len = sock.recvFrom(&response_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };

            // Parse response
            return parseResponse(response_buf[0..response_len]) catch return error.ResponseParseFailed;
        }

        fn resolveTcp(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            var sock = socket.tcp() catch return error.SocketError;
            defer sock.close();

            sock.setRecvTimeout(self.timeout_ms);
            sock.setSendTimeout(self.timeout_ms);

            // Connect to DNS server
            sock.connect(self.server, 53) catch return error.SocketError;

            // Build query
            var query_buf: [514]u8 = undefined; // 2 bytes length prefix + 512 query
            const query_len = buildQuery(query_buf[2..], hostname, generateTxId()) catch return error.QueryBuildFailed;

            // TCP DNS: prepend 2-byte length
            query_buf[0] = @intCast((query_len >> 8) & 0xFF);
            query_buf[1] = @intCast(query_len & 0xFF);

            // Send query
            _ = sock.send(query_buf[0 .. query_len + 2]) catch return error.SocketError;

            // Receive length prefix
            var len_buf: [2]u8 = undefined;
            _ = sock.recv(&len_buf) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };
            const response_len: usize = (@as(usize, len_buf[0]) << 8) | len_buf[1];

            // Receive response
            var response_buf: [512]u8 = undefined;
            if (response_len > response_buf.len) return error.ResponseParseFailed;

            var total_read: usize = 0;
            while (total_read < response_len) {
                const n = sock.recv(response_buf[total_read..response_len]) catch |err| {
                    return switch (err) {
                        error.Timeout => error.Timeout,
                        else => error.SocketError,
                    };
                };
                if (n == 0) break;
                total_read += n;
            }

            // Parse response
            return parseResponse(response_buf[0..total_read]) catch return error.ResponseParseFailed;
        }

        fn resolveHttps(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
            // DNS over HTTPS (DoH) - RFC 8484
            // TLS on freestanding requires platform-specific implementation.
            // For ESP32, use esp.net.DnsResolver which wraps esp_http_client.
            _ = self;
            _ = hostname;
            return error.TlsError; // DoH not supported in generic resolver
        }
    };
}

// ============================================================================
// DNS Protocol Helpers
// ============================================================================

/// Simple transaction ID generator
var tx_id_counter: u16 = 0x1234;

fn generateTxId() u16 {
    tx_id_counter +%= 1;
    return tx_id_counter;
}

/// Build DNS query packet
pub fn buildQuery(buf: []u8, hostname: []const u8, transaction_id: u16) !usize {
    if (hostname.len == 0 or hostname.len > 253) return error.InvalidHostname;

    var pos: usize = 0;

    // Transaction ID
    buf[pos] = @intCast((transaction_id >> 8) & 0xFF);
    buf[pos + 1] = @intCast(transaction_id & 0xFF);
    pos += 2;

    // Flags: standard query, recursion desired
    buf[pos] = 0x01;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Questions: 1
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Answer RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Authority RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Additional RRs: 0
    buf[pos] = 0x00;
    buf[pos + 1] = 0x00;
    pos += 2;

    // Question section: encode hostname
    // "www.google.com" -> "\x03www\x06google\x03com\x00"
    var label_start = pos;
    pos += 1; // reserve space for label length

    for (hostname) |ch| {
        if (ch == '.') {
            // Write label length
            buf[label_start] = @intCast(pos - label_start - 1);
            label_start = pos;
            pos += 1;
        } else {
            buf[pos] = ch;
            pos += 1;
        }
    }
    // Last label
    buf[label_start] = @intCast(pos - label_start - 1);
    buf[pos] = 0x00; // null terminator
    pos += 1;

    // Type: A (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    // Class: IN (1)
    buf[pos] = 0x00;
    buf[pos + 1] = 0x01;
    pos += 2;

    return pos;
}

/// Parse DNS response and extract first A record
pub fn parseResponse(data: []const u8) !Ipv4Address {
    if (data.len < 12) return error.ResponseParseFailed;

    // Check response code (lower 4 bits of byte 3)
    const rcode = data[3] & 0x0F;
    if (rcode != 0) return error.NoAnswer;

    // Get answer count
    const answer_count = (@as(u16, data[6]) << 8) | data[7];
    if (answer_count == 0) return error.NoAnswer;

    // Skip header (12 bytes)
    var pos: usize = 12;

    // Skip question section
    while (pos < data.len and data[pos] != 0) {
        if ((data[pos] & 0xC0) == 0xC0) {
            // Compression pointer
            pos += 2;
            break;
        }
        pos += @as(usize, data[pos]) + 1;
    }
    if (pos < data.len and data[pos] == 0) pos += 1;
    pos += 4; // Skip QTYPE and QCLASS

    // Parse answers
    var i: u16 = 0;
    while (i < answer_count and pos + 12 <= data.len) : (i += 1) {
        // Skip name (handle compression)
        if ((data[pos] & 0xC0) == 0xC0) {
            pos += 2;
        } else {
            while (pos < data.len and data[pos] != 0) {
                pos += @as(usize, data[pos]) + 1;
            }
            pos += 1;
        }

        if (pos + 10 > data.len) break;

        const rtype = (@as(u16, data[pos]) << 8) | data[pos + 1];
        pos += 2;
        // Skip class
        pos += 2;
        // Skip TTL
        pos += 4;
        const rdlength = (@as(u16, data[pos]) << 8) | data[pos + 1];
        pos += 2;

        // Type A (1) with 4-byte address
        if (rtype == 1 and rdlength == 4 and pos + 4 <= data.len) {
            return .{ data[pos], data[pos + 1], data[pos + 2], data[pos + 3] };
        }

        pos += rdlength;
    }

    return error.NoAnswer;
}

/// Format IPv4 address as string
pub fn formatIpv4(addr: Ipv4Address, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ addr[0], addr[1], addr[2], addr[3] }) catch "?.?.?.?";
}

// ============================================================================
// Tests
// ============================================================================

test "buildQuery" {
    var buf: [512]u8 = undefined;
    const len = try buildQuery(&buf, "www.google.com", 0x1234);

    // Check transaction ID
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);

    // Check query is reasonable length
    try std.testing.expect(len > 12);
    try std.testing.expect(len < 100);
}
