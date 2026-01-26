//! TLS Abstraction
//!
//! Provides cross-platform TLS interface for encrypted communication.
//!
//! Platform implementations should provide:
//!   - TLS handshake with server
//!   - Encrypted send/receive operations
//!   - Certificate verification options
//!
//! Example:
//!   // Create TLS stream from existing socket
//!   var tls = try sal.tls.create(socket);
//!   defer tls.deinit();
//!
//!   // Perform handshake
//!   try tls.handshake("www.example.com");
//!
//!   // Send/receive encrypted data
//!   _ = try tls.send("GET / HTTP/1.0\r\n\r\n");
//!   const n = try tls.recv(&buf);

const std = @import("std");

/// TLS errors
pub const TlsError = error{
    InitFailed,
    HandshakeFailed,
    CertificateError,
    SendFailed,
    RecvFailed,
    Timeout,
    ConnectionClosed,
    OutOfMemory,
};

/// TLS configuration options
pub const Options = struct {
    /// Skip server certificate verification (insecure, for testing)
    skip_cert_verify: bool = false,
    /// Connection timeout in milliseconds
    timeout_ms: u32 = 30000,
};

/// TLS Stream - wraps a socket with TLS encryption
///
/// Generic interface - platform implementations provide the actual type.
/// Use comptime socket type for zero-cost abstraction.
pub fn TlsStream(comptime Socket: type) type {
    return struct {
        /// Platform-specific implementation data
        impl: *anyopaque,
        socket: Socket,

        const Self = @This();

        /// Initialize TLS context for a socket
        pub fn init(socket: Socket, options: Options) TlsError!Self {
            _ = socket;
            _ = options;
            @compileError("sal.tls.TlsStream.init requires platform implementation");
        }

        /// Perform TLS handshake with server
        pub fn handshake(self: *Self, hostname: []const u8) TlsError!void {
            _ = self;
            _ = hostname;
            @compileError("sal.tls.TlsStream.handshake requires platform implementation");
        }

        /// Send encrypted data
        pub fn send(self: *Self, data: []const u8) TlsError!usize {
            _ = self;
            _ = data;
            @compileError("sal.tls.TlsStream.send requires platform implementation");
        }

        /// Receive decrypted data
        pub fn recv(self: *Self, buf: []u8) TlsError!usize {
            _ = self;
            _ = buf;
            @compileError("sal.tls.TlsStream.recv requires platform implementation");
        }

        /// Close TLS connection and free resources
        pub fn deinit(self: *Self) void {
            _ = self;
            @compileError("sal.tls.TlsStream.deinit requires platform implementation");
        }
    };
}

/// Create TLS stream from socket (convenience function)
pub fn create(comptime Socket: type, socket: Socket, options: Options) TlsError!TlsStream(Socket) {
    return TlsStream(Socket).init(socket, options);
}
