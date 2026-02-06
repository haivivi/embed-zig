//! Pure Zig TLS Library
//!
//! Platform-independent TLS 1.2/1.3 implementation.
//! Designed for embedded systems with configurable memory allocation.
//!
//! ## Features
//!
//! - TLS 1.3 and TLS 1.2 client support
//! - Platform-independent (works on ESP32, desktop, etc.)
//! - Configurable allocator (supports PSRAM, Flash, etc.)
//! - Fully generic over crypto implementation (via trait.crypto interface)
//! - Crypto type includes Rng (Crypto.Rng.fill) - no separate Rng parameter
//!
//! ## Supported Cipher Suites
//!
//! ### TLS 1.3
//! - TLS_AES_128_GCM_SHA256
//! - TLS_AES_256_GCM_SHA384
//! - TLS_CHACHA20_POLY1305_SHA256
//!
//! ### TLS 1.2
//! - TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256
//! - TLS_ECDHE_RSA_WITH_AES_256_GCM_SHA384
//! - TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256
//! - TLS_ECDHE_RSA_WITH_CHACHA20_POLY1305_SHA256
//!
//! ## Usage
//!
//! ```zig
//! const tls = @import("tls");
//!
//! // With platform socket and crypto (Crypto includes Rng)
//! const Socket = MyPlatformSocket;
//! const Crypto = Board.crypto; // platform-specific crypto (trait.crypto compatible)
//!
//! var socket = try Socket.tcp();
//! try socket.connect(ip, 443);
//!
//! var client = try tls.Client(Socket, Crypto).init(&socket, .{
//!     .allocator = allocator,
//!     .hostname = "example.com",
//! });
//! defer client.deinit();
//!
//! try client.connect();
//!
//! _ = try client.send("GET / HTTP/1.1\r\nHost: example.com\r\n\r\n");
//!
//! var buf: [4096]u8 = undefined;
//! const n = try client.recv(&buf);
//! ```

const std = @import("std");

// Re-export submodules
pub const common = @import("common.zig");
pub const record = @import("record.zig");
pub const handshake = @import("handshake.zig");
pub const alert = @import("alert.zig");
pub const extensions = @import("extensions.zig");
pub const client = @import("client.zig");
pub const stream = @import("stream.zig");
pub const kdf = @import("kdf.zig");

// Re-export main types
pub const Client = client.Client;
pub const Config = client.Config;
pub const Stream = stream.Stream;
pub const StreamWithAllocator = stream.StreamWithAllocator;
pub const StreamOptions = stream.Options;

// Re-export common types
pub const ProtocolVersion = common.ProtocolVersion;
pub const CipherSuite = common.CipherSuite;
pub const ContentType = common.ContentType;
pub const HandshakeType = common.HandshakeType;
pub const NamedGroup = common.NamedGroup;
pub const SignatureScheme = common.SignatureScheme;
pub const Alert = common.Alert;
pub const AlertLevel = common.AlertLevel;
pub const AlertDescription = common.AlertDescription;

// Constants
pub const MAX_PLAINTEXT_LEN = common.MAX_PLAINTEXT_LEN;
pub const MAX_CIPHERTEXT_LEN = common.MAX_CIPHERTEXT_LEN;
pub const RECORD_HEADER_LEN = common.RECORD_HEADER_LEN;

// Convenience function
pub const connect = client.connect;

// ============================================================================
// Tests
// ============================================================================

test {
    _ = common;
    _ = record;
    _ = handshake;
    _ = alert;
    _ = extensions;
    _ = client;
    _ = stream;
    _ = kdf;
}
