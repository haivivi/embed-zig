//! Stream adapter for trait.socket
//!
//! Provides simple read/write interface for HTTP client.

const std = @import("std");
const trait = @import("trait");

/// Socket Stream - wraps a generic socket type with read/write interface
pub fn SocketStream(comptime Socket: type) type {
    const socket = trait.socket.from(Socket);

    return struct {
        inner: socket,

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

        pub fn init(s: socket) Self {
            return .{ .inner = s };
        }

        /// Read from socket
        pub fn read(self: *Self, dest: []u8) ReadError!usize {
            const n = self.inner.recv(dest) catch |err| {
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
            return self.inner.send(data) catch |err| {
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
            self.inner.close();
        }
    };
}

