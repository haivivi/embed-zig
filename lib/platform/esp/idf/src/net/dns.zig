//! ESP DNS Resolver
//!
//! Pre-configured DNS resolver using LWIP socket implementation.
//! Supports UDP, TCP, and HTTPS (DoH via esp_http_client).
//!
//! Example:
//!   const esp = @import("esp");
//!
//!   var resolver = esp.DnsResolver{
//!       .server = .{ 223, 5, 5, 5 },  // AliDNS
//!       .protocol = .udp,  // or .tcp, .https
//!   };
//!
//!   const ip = try resolver.resolve("www.google.com");

const std = @import("std");

const dns_lib = @import("dns");
/// DNS Protocol
pub const Protocol = dns_lib.Protocol;
/// DNS Errors
pub const DnsError = dns_lib.DnsError;
/// IPv4 Address
pub const Ipv4Address = dns_lib.Ipv4Address;
/// Format IPv4 address as string
pub const formatIpv4 = dns_lib.formatIpv4;
/// Build DNS query
pub const buildQuery = dns_lib.buildQuery;
/// Parse DNS response
pub const parseResponse = dns_lib.parseResponse;

const http = @import("../http.zig");
const socket_mod = @import("../socket.zig");

/// Base DNS resolver using LWIP socket (for UDP/TCP)
const BaseDnsResolver = dns_lib.Resolver(socket_mod.Socket);

/// ESP DNS Resolver with HTTPS support via esp_http_client
pub const DnsResolver = struct {
    /// DNS server address (for UDP/TCP)
    server: Ipv4Address = .{ 8, 8, 8, 8 },

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
            .udp, .tcp => {
                // Use base resolver for UDP/TCP
                const base = BaseDnsResolver{
                    .server = self.server,
                    .protocol = self.protocol,
                    .timeout_ms = self.timeout_ms,
                };
                return base.resolve(hostname);
            },
            .https => self.resolveHttps(hostname),
        };
    }

    /// DNS over HTTPS using esp_http_client
    fn resolveHttps(self: *const Self, hostname: []const u8) DnsError!Ipv4Address {
        // Build DNS query
        var query_buf: [512]u8 = undefined;
        const query_len = buildQuery(&query_buf, hostname, generateTxId()) catch return error.QueryBuildFailed;
        const query_data = query_buf[0..query_len];

        // Build DoH URL
        var url_buf: [256]u8 = undefined;
        const url = std.fmt.bufPrint(&url_buf, "https://{s}/dns-query", .{self.doh_host}) catch return error.QueryBuildFailed;

        // Make HTTPS POST request using esp_http_client
        var response_buf: [1024]u8 = undefined;
        const response_len = http.postDns(url, query_data, &response_buf, self.timeout_ms) catch return error.HttpError;

        if (response_len == 0) return error.NoAnswer;

        // Parse DNS response
        return parseResponse(response_buf[0..response_len]) catch return error.ResponseParseFailed;
    }
};

/// Simple transaction ID generator
var tx_id_counter: u16 = 0x5678;

fn generateTxId() u16 {
    tx_id_counter +%= 1;
    return tx_id_counter;
}
