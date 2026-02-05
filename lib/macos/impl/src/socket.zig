//! Socket - macOS POSIX Implementation
//!
//! BSD socket wrapper using std.posix.

const std = @import("std");
const posix = std.posix;

pub const SocketError = error{
    CreateFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    Closed,
};

pub const Socket = struct {
    fd: posix.socket_t,

    const Self = @This();

    /// Create a TCP socket
    pub fn tcp() SocketError!Socket {
        const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
            return error.CreateFailed;
        };
        return Socket{ .fd = fd };
    }

    /// Connect to a remote address
    pub fn connect(self: *Self, ip: [4]u8, port: u16) SocketError!void {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(ip),
        };
        posix.connect(self.fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in)) catch {
            return error.ConnectFailed;
        };
    }

    /// Send data
    pub fn send(self: *Self, data: []const u8) SocketError!usize {
        const result = posix.send(self.fd, data, 0) catch |err| {
            if (err == error.WouldBlock) {
                return error.Timeout;
            }
            return error.SendFailed;
        };
        return result;
    }

    /// Receive data
    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        const result = posix.recv(self.fd, buf, 0) catch |err| {
            if (err == error.WouldBlock) {
                return error.Timeout;
            }
            return error.RecvFailed;
        };
        if (result == 0) {
            return error.Closed;
        }
        return result;
    }

    /// Close the socket
    pub fn close(self: *Self) void {
        posix.close(self.fd);
    }

    /// Set receive timeout in milliseconds
    pub fn setRecvTimeout(self: *Self, timeout_ms: u32) void {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch |err| {
            std.debug.print("Warning: failed to set socket recv timeout: {}\n", .{err});
        };
    }

    /// Set send timeout in milliseconds
    pub fn setSendTimeout(self: *Self, timeout_ms: u32) void {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch |err| {
            std.debug.print("Warning: failed to set socket send timeout: {}\n", .{err});
        };
    }
};
