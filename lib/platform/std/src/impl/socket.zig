//! SAL Socket Implementation - Zig std
//!
//! Implements trait.socket interface using std.posix sockets.
//! Compatible with DNS resolver and TLS client.

const std = @import("std");
const posix = std.posix;
const trait = @import("trait");

/// IPv4 address (matches trait.socket.Ipv4Address)
pub const Ipv4Address = trait.socket.Ipv4Address;

/// Socket error (matches trait.socket.Error)
pub const Error = trait.socket.Error;

/// Socket implementation matching trait.socket interface
pub const Socket = struct {
    fd: posix.socket_t,

    const Self = @This();

    // ========================================================================
    // Static methods (required by trait.socket)
    // ========================================================================

    /// Create a TCP socket
    pub fn tcp() Error!Self {
        const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
            return error.CreateFailed;
        };
        return .{ .fd = fd };
    }

    /// Create a UDP socket
    pub fn udp() Error!Self {
        const fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch {
            return error.CreateFailed;
        };
        return .{ .fd = fd };
    }

    // ========================================================================
    // Instance methods (required by trait.socket)
    // ========================================================================

    /// Close the socket
    pub fn close(self: *Self) void {
        posix.close(self.fd);
    }

    /// Connect to an IPv4 address and port
    pub fn connect(self: *Self, ip: Ipv4Address, port: u16) Error!void {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(ip),
        };
        posix.connect(self.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch {
            return error.ConnectFailed;
        };
    }

    /// Send data on connected socket
    pub fn send(self: *Self, data: []const u8) Error!usize {
        return posix.send(self.fd, data, 0) catch {
            return error.SendFailed;
        };
    }

    /// Receive data from socket
    pub fn recv(self: *Self, buf: []u8) Error!usize {
        const n = posix.recv(self.fd, buf, 0) catch |err| {
            return switch (err) {
                error.WouldBlock => error.Timeout,
                error.ConnectionResetByPeer => error.Closed,
                else => error.RecvFailed,
            };
        };
        if (n == 0) return error.Closed;
        return n;
    }

    /// Set receive timeout in milliseconds
    pub fn setRecvTimeout(self: *Self, timeout_ms: u32) void {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    /// Set send timeout in milliseconds
    pub fn setSendTimeout(self: *Self, timeout_ms: u32) void {
        const tv = posix.timeval{
            .sec = @intCast(timeout_ms / 1000),
            .usec = @intCast((timeout_ms % 1000) * 1000),
        };
        posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&tv)) catch {};
    }

    /// Enable/disable TCP_NODELAY (Nagle's algorithm)
    pub fn setTcpNoDelay(self: *Self, enable: bool) void {
        const val: u32 = if (enable) 1 else 0;
        posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&val)) catch {};
    }

    /// Send data to a specific address (UDP)
    pub fn sendTo(self: *Self, ip: Ipv4Address, port: u16, data: []const u8) Error!usize {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(ip),
        };
        return posix.sendto(self.fd, data, 0, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch {
            return error.SendFailed;
        };
    }

    /// Receive data from socket (UDP - ignores sender address)
    pub fn recvFrom(self: *Self, buf: []u8) Error!usize {
        var src_addr: posix.sockaddr.storage = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
        const n = posix.recvfrom(self.fd, buf, 0, @ptrCast(&src_addr), &addr_len) catch {
            return error.RecvFailed;
        };
        if (n == 0) return error.Closed;
        return n;
    }

    /// Receive data from socket (UDP - returns sender address for security validation)
    pub fn recvFromWithAddr(self: *Self, buf: []u8) Error!trait.socket.RecvFromResult {
        var src_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const n = posix.recvfrom(self.fd, buf, 0, @ptrCast(&src_addr), &addr_len) catch |err| {
            // Fix #10: map EAGAIN/EWOULDBLOCK to Timeout for non-blocking sockets
            return if (err == error.WouldBlock) error.Timeout else error.RecvFailed;
        };
        if (n == 0) return error.Closed;
        
        const ip: Ipv4Address = @bitCast(src_addr.addr);
        return .{
            .len = n,
            .src_addr = ip,
            .src_port = std.mem.bigToNative(u16, src_addr.port),
        };
    }

    /// Bind socket to a local address and port
    pub fn bind(self: *Self, ip: Ipv4Address, port: u16) Error!void {
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = @bitCast(ip),
        };
        posix.bind(self.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) catch {
            return error.BindFailed;
        };
    }

    /// Get the port that the socket is bound to (useful after bind(port=0))
    pub fn getBoundPort(self: *Self) Error!u16 {
        var addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        posix.getsockname(self.fd, @ptrCast(&addr), &addr_len) catch {
            return error.InvalidAddress;
        };
        return std.mem.bigToNative(u16, addr.port);
    }

    /// Listen for incoming connections (TCP server)
    pub fn listen(self: *Self) Error!void {
        posix.listen(self.fd, 128) catch {
            return error.ListenFailed;
        };
    }

    /// Accept an incoming connection (TCP server)
    pub fn accept(self: *Self) Error!Self {
        var client_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        const client_fd = posix.accept(self.fd, @ptrCast(&client_addr), &addr_len, 0) catch {
            return error.AcceptFailed;
        };
        return .{ .fd = client_fd };
    }

    /// Get the underlying file descriptor
    pub fn getFd(self: *Self) i32 {
        return @intCast(self.fd);
    }

    /// Set socket to non-blocking mode (for async IO with kqueue/epoll)
    pub fn setNonBlocking(self: *Self, enable: bool) Error!void {
        const flags = posix.fcntl(self.fd, posix.F.GETFL, 0) catch {
            return error.InvalidAddress;
        };
        // O_NONBLOCK = 0x0004 on macOS/BSD, 0x0800 on Linux
        const O_NONBLOCK: u32 = if (@hasDecl(posix.O, "NONBLOCK"))
            @intFromEnum(posix.O.NONBLOCK)
        else
            0x0004; // macOS default
        const new_flags = if (enable) flags | O_NONBLOCK else flags & ~O_NONBLOCK;
        _ = posix.fcntl(self.fd, posix.F.SETFL, new_flags) catch {
            return error.InvalidAddress;
        };
    }
};

// ============================================================================
// Tests
// ============================================================================

test "Socket matches trait.socket interface" {
    // This will fail at compile time if Socket doesn't match the trait
    _ = trait.socket.from(Socket);
}

test "create TCP socket" {
    var sock = try Socket.tcp();
    defer sock.close();
    try std.testing.expect(sock.getFd() >= 0);
}

test "create UDP socket" {
    var sock = try Socket.udp();
    defer sock.close();
    try std.testing.expect(sock.getFd() >= 0);
}

test "set socket options" {
    var sock = try Socket.tcp();
    defer sock.close();
    sock.setRecvTimeout(5000);
    sock.setSendTimeout(5000);
    sock.setTcpNoDelay(true);
}
