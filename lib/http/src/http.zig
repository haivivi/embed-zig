//! HTTP Client Library
//!
//! A simple HTTP/1.1 client that works with trait.socket abstraction.
//! Supports HTTP (plain), HTTPS (with platform TLS), and DNS resolution.
//!
//! ## HTTP Only (IP addresses only)
//!
//! ```zig
//! const HttpClient = http.Client(Socket);
//! var client = HttpClient{};
//! const resp = try client.get("http://192.168.1.100/api", &buffer);
//! ```
//!
//! ## HTTP + HTTPS
//!
//! ```zig
//! const HttpClient = http.ClientWithTls(Socket, TlsStream);
//! var client = HttpClient{ .skip_cert_verify = true };
//! const resp = try client.get("https://192.168.1.100/api", &buffer);
//! ```
//!
//! ## HTTP + DNS Resolver
//!
//! ```zig
//! const HttpClient = http.ClientWithResolver(Socket, DnsResolver);
//! var resolver = DnsResolver.init();
//! var client = HttpClient{ .resolver = &resolver };
//! const resp = try client.get("http://example.com/api", &buffer);
//! ```
//!
//! ## Full Featured (HTTP + HTTPS + DNS)
//!
//! ```zig
//! const HttpClient = http.ClientFull(Socket, TlsStream, DnsResolver);
//! var resolver = DnsResolver.init();
//! var client = HttpClient{ .resolver = &resolver, .skip_cert_verify = false };
//! const resp = try client.get("https://example.com/api", &buffer);
//! ```
//!
//! ## Resolver Interface
//!
//! The resolver type must have a `resolve` method:
//! ```zig
//! fn resolve(self: *Resolver, host: []const u8) ?[4]u8
//! ```

pub const client = @import("client.zig");
pub const Client = client.Client;
pub const ClientWithTls = client.ClientWithTls;
pub const ClientWithResolver = client.ClientWithResolver;
pub const ClientFull = client.ClientFull;
pub const Method = client.Method;
pub const Response = client.Response;
pub const ClientError = client.ClientError;
pub const stream = @import("stream.zig");
pub const SocketStream = stream.SocketStream;
// TLS interface is defined in trait.tls (trait.tls.from, trait.tls.Options, trait.tls.Error)

// Re-exports for convenience

const trait = @import("trait");

/// Simple GET request (HTTP only, IP addresses only)
pub fn get(comptime Socket: type, url: []const u8, buffer: []u8) ClientError!Response {
    const socket = trait.socket.from(Socket);
    const HttpClient = Client(socket);
    const c = HttpClient{};
    return c.get(url, buffer);
}

/// Simple POST request (HTTP only, IP addresses only)
pub fn post(comptime Socket: type, url: []const u8, body: ?[]const u8, buffer: []u8) ClientError!Response {
    const socket = trait.socket.from(Socket);
    const HttpClient = Client(socket);
    const c = HttpClient{};
    return c.post(url, body, buffer);
}
