//! Stream adapter for sal.socket
//!
//! Provides simple read/write interface for HTTP client.
//! TLS support is provided by platform-specific implementations (e.g., esp.sal.tls).

const std = @import("std");

/// Socket Stream - wraps a generic socket type with read/write interface
pub fn SocketStream(comptime Socket: type) type {
    return struct {
        socket: Socket,

        const Self = @This();

        pub const ReadError = error{
            SocketError,
            Timeout,
            ConnectionClosed,
        };

        pub const WriteError = error{
            SocketError,
            Timeout,
        };

        pub fn init(socket: Socket) Self {
            return .{ .socket = socket };
        }

        /// Read from socket
        pub fn read(self: *Self, dest: []u8) ReadError!usize {
            const n = self.socket.recv(dest) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    error.Closed => error.ConnectionClosed,
                    else => error.SocketError,
                };
            };
            return n;
        }

        /// Write to socket
        pub fn write(self: *Self, data: []const u8) WriteError!usize {
            return self.socket.send(data) catch |err| {
                return switch (err) {
                    error.Timeout => error.Timeout,
                    else => error.SocketError,
                };
            };
        }

        /// Write all data
        pub fn writeAll(self: *Self, data: []const u8) WriteError!void {
            var sent: usize = 0;
            while (sent < data.len) {
                sent += try self.write(data[sent..]);
            }
        }

        /// Close socket
        pub fn close(self: *Self) void {
            self.socket.close();
        }
    };
}

/// TLS Stream Interface
///
/// This is an interface definition for TLS implementations.
/// Platform-specific implementations (like esp.sal.tls.TlsStream) should provide:
/// - init(socket, options) -> TlsStream
/// - handshake(hostname) -> error!void
/// - send(data) -> error!usize
/// - recv(buf) -> error!usize
/// - deinit() -> void
///
/// Example usage:
///   const TlsStream = esp.sal.tls.TlsStream;
///   const HttpClient = http.ClientWithTls(Socket, TlsStream);
pub const TlsStreamInterface = struct {
    pub const Error = error{
        InitFailed,
        HandshakeFailed,
        SendFailed,
        RecvFailed,
        ConnectionClosed,
    };

    pub const Options = struct {
        skip_cert_verify: bool = false,
        timeout_ms: u32 = 30000,
    };
};
