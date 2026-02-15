//! HTTP Client Library
//!
//! A simple HTTP/1.1 client with built-in pure Zig TLS and DNS resolver.
//!
//! ## Full Featured (HTTP + HTTPS + DNS) - Recommended
//!
//! ```zig
//! const http = @import("http");
//! const crypto = @import("crypto");
//! const Rt = @import("std_impl").runtime; // or esp.idf.runtime
//!
//! // Create full-featured client with built-in TLS and DNS
//! const Client = http.HttpClient(Socket, crypto.Suite, Rt, void);
//! var client = Client{
//!     .allocator = allocator,
//!     .dns_server = .{ 223, 5, 5, 5 },  // AliDNS
//!     .skip_cert_verify = true,
//! };
//!
//! var buffer: [8192]u8 = undefined;
//! const resp = try client.get("https://example.com/api", &buffer);
//! ```
//!
//! ## HTTP Only (IP addresses only, no TLS, no DNS)
//!
//! ```zig
//! const Client = http.Client(Socket);
//! var client = Client{};
//! const resp = try client.get("http://192.168.1.100/api", &buffer);
//! ```

pub const client = @import("client.zig");

/// Full-featured HTTP Client with built-in TLS and DNS
///
/// - Socket: Platform socket type
/// - Crypto: Crypto suite (must include Rng)
/// - Rt: Runtime providing Mutex (for TLS thread safety)
/// - DomainResolver: Custom domain resolver (void to disable)
pub const HttpClient = client.HttpClient;

/// HTTP-only Client (no TLS, no DNS resolver)
/// Use this for simple HTTP requests to IP addresses.
pub const Client = client.Client;

pub const Method = client.Method;
pub const Response = client.Response;
pub const ClientError = client.ClientError;

pub const stream = @import("stream.zig");
pub const SocketStream = stream.SocketStream;
