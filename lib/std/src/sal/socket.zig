//! SAL Socket Implementation - Zig std
//!
//! Implements sal.socket interface using std.posix sockets.

const std = @import("std");
const posix = std.posix;

// ============================================================================
// Types (matching sal.socket interface)
// ============================================================================

/// IPv4 address (4 bytes)
pub const Ipv4Address = [4]u8;

/// IPv6 address (16 bytes)
pub const Ipv6Address = [16]u8;

/// Socket address
pub const Address = union(enum) {
    ipv4: Ipv4Address,
    ipv6: Ipv6Address,

    /// Format address as string
    pub fn format(self: Address, buf: []u8) []const u8 {
        return switch (self) {
            .ipv4 => |addr| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                addr[0],
                addr[1],
                addr[2],
                addr[3],
            }) catch "?.?.?.?",
            .ipv6 => "ipv6", // TODO: proper formatting
        };
    }

    /// Parse IPv4 address string (e.g., "192.168.1.1")
    pub fn parseIpv4(str: []const u8) ?Address {
        var addr: Ipv4Address = undefined;
        var idx: usize = 0;
        var num: u16 = 0;
        var dots: u8 = 0;

        for (str) |ch| {
            if (ch >= '0' and ch <= '9') {
                num = num * 10 + (ch - '0');
                if (num > 255) return null;
            } else if (ch == '.') {
                if (idx >= 4) return null;
                addr[idx] = @intCast(num);
                idx += 1;
                num = 0;
                dots += 1;
            } else {
                return null;
            }
        }

        if (dots != 3 or idx != 3) return null;
        addr[3] = @intCast(num);
        return .{ .ipv4 = addr };
    }

    /// Convert to std.net.Address
    pub fn toStdAddress(self: Address, port: u16) std.net.Address {
        return switch (self) {
            .ipv4 => |addr| std.net.Address.initIp4(addr, port),
            .ipv6 => |addr| std.net.Address.initIp6(addr, port, 0, 0),
        };
    }
};

/// Socket errors
pub const SocketError = error{
    CreateFailed,
    BindFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    InvalidAddress,
    BindToDeviceFailed,
    Closed,
};

/// Socket protocol type
pub const Protocol = enum {
    tcp,
    udp,
};

/// Socket options
pub const Options = struct {
    /// Receive timeout in milliseconds (0 = no timeout)
    recv_timeout_ms: u32 = 0,
    /// Send timeout in milliseconds (0 = no timeout)
    send_timeout_ms: u32 = 0,
    /// Receive buffer size (0 = system default)
    recv_buffer_size: u32 = 0,
    /// Send buffer size (0 = system default)
    send_buffer_size: u32 = 0,
    /// Enable TCP_NODELAY (disable Nagle's algorithm)
    tcp_nodelay: bool = false,
};

// ============================================================================
// Socket Implementation
// ============================================================================

/// Socket handle using std.posix
pub const Socket = struct {
    fd: posix.socket_t,
    protocol: Protocol,

    const Self = @This();

    /// Close the socket
    pub fn close(self: Self) void {
        posix.close(self.fd);
    }

    /// Connect to an address (for TCP)
    pub fn connect(self: Self, addr: Address, port: u16) SocketError!void {
        const std_addr = addr.toStdAddress(port);
        posix.connect(self.fd, &std_addr.any, std_addr.getOsSockLen()) catch {
            return error.ConnectFailed;
        };
    }

    /// Send data (for connected socket)
    pub fn send(self: Self, data: []const u8) SocketError!usize {
        const sent = posix.send(self.fd, data, 0) catch {
            return error.SendFailed;
        };
        return sent;
    }

    /// Receive data
    pub fn recv(self: Self, buf: []u8) SocketError!usize {
        const received = posix.recv(self.fd, buf, 0) catch {
            return error.RecvFailed;
        };
        if (received == 0) {
            return error.Closed;
        }
        return received;
    }

    /// Send data to a specific address (for UDP)
    pub fn sendTo(self: Self, addr: Address, port: u16, data: []const u8) SocketError!usize {
        const std_addr = addr.toStdAddress(port);
        const sent = posix.sendto(self.fd, data, 0, &std_addr.any, std_addr.getOsSockLen()) catch {
            return error.SendFailed;
        };
        return sent;
    }

    /// Receive data from (for UDP), returns sender address
    pub fn recvFrom(self: Self, buf: []u8) SocketError!struct { len: usize, addr: Address, port: u16 } {
        var src_addr: posix.sockaddr.storage = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);

        const received = posix.recvfrom(self.fd, buf, 0, @ptrCast(&src_addr), &addr_len) catch {
            return error.RecvFailed;
        };

        if (received == 0) {
            return error.Closed;
        }

        // Parse source address
        const std_addr = std.net.Address{ .any = @bitCast(src_addr) };
        const addr: Address = switch (std_addr.any.family) {
            posix.AF.INET => .{ .ipv4 = std_addr.in.sa.addr },
            posix.AF.INET6 => .{ .ipv6 = std_addr.in6.sa.addr },
            else => return error.InvalidAddress,
        };
        const port = std_addr.getPort();

        return .{ .len = received, .addr = addr, .port = port };
    }

    /// Set socket options
    pub fn setOptions(self: Self, options: Options) void {
        // Receive timeout
        if (options.recv_timeout_ms > 0) {
            const timeout = posix.timeval{
                .sec = @intCast(options.recv_timeout_ms / 1000),
                .usec = @intCast((options.recv_timeout_ms % 1000) * 1000),
            };
            _ = posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&timeout)) catch {};
        }

        // Send timeout
        if (options.send_timeout_ms > 0) {
            const timeout = posix.timeval{
                .sec = @intCast(options.send_timeout_ms / 1000),
                .usec = @intCast((options.send_timeout_ms % 1000) * 1000),
            };
            _ = posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDTIMEO, std.mem.asBytes(&timeout)) catch {};
        }

        // Receive buffer size
        if (options.recv_buffer_size > 0) {
            _ = posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&options.recv_buffer_size)) catch {};
        }

        // Send buffer size
        if (options.send_buffer_size > 0) {
            _ = posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&options.send_buffer_size)) catch {};
        }

        // TCP_NODELAY
        if (options.tcp_nodelay and self.protocol == .tcp) {
            const nodelay: u32 = 1;
            _ = posix.setsockopt(self.fd, posix.IPPROTO.TCP, posix.TCP.NODELAY, std.mem.asBytes(&nodelay)) catch {};
        }
    }

    /// Bind socket to a specific network interface
    pub fn bindToDevice(self: Self, interface_name: []const u8) SocketError!void {
        // SO_BINDTODEVICE is Linux-specific
        if (@hasDecl(posix.SO, "BINDTODEVICE")) {
            var name_buf: [16]u8 = undefined;
            const len = @min(interface_name.len, name_buf.len - 1);
            @memcpy(name_buf[0..len], interface_name[0..len]);
            name_buf[len] = 0;

            _ = posix.setsockopt(self.fd, posix.SOL.SOCKET, posix.SO.BINDTODEVICE, name_buf[0 .. len + 1]) catch {
                return error.BindToDeviceFailed;
            };
        } else {
            return error.BindToDeviceFailed;
        }
    }

    /// Get the underlying file descriptor
    pub fn getFd(self: Self) i32 {
        return @intCast(self.fd);
    }
};

/// Create a TCP socket
pub fn tcp() SocketError!Socket {
    const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0) catch {
        return error.CreateFailed;
    };
    return Socket{ .fd = fd, .protocol = .tcp };
}

/// Create a UDP socket
pub fn udp() SocketError!Socket {
    const fd = posix.socket(posix.AF.INET, posix.SOCK.DGRAM, 0) catch {
        return error.CreateFailed;
    };
    return Socket{ .fd = fd, .protocol = .udp };
}

/// Create a socket with options
pub fn create(protocol: Protocol, options: Options) SocketError!Socket {
    const sock = switch (protocol) {
        .tcp => try tcp(),
        .udp => try udp(),
    };
    sock.setOptions(options);
    return sock;
}

// ============================================================================
// Tests
// ============================================================================

test "Address parseIpv4" {
    const addr = Address.parseIpv4("192.168.1.100");
    try std.testing.expect(addr != null);
    try std.testing.expectEqual(Ipv4Address{ 192, 168, 1, 100 }, addr.?.ipv4);
}

test "Address parseIpv4 invalid" {
    try std.testing.expect(Address.parseIpv4("256.1.1.1") == null);
    try std.testing.expect(Address.parseIpv4("1.2.3") == null);
    try std.testing.expect(Address.parseIpv4("1.2.3.4.5") == null);
    try std.testing.expect(Address.parseIpv4("abc") == null);
}

test "Address format" {
    const addr = Address{ .ipv4 = .{ 192, 168, 1, 100 } };
    var buf: [32]u8 = undefined;
    const str = addr.format(&buf);
    try std.testing.expectEqualStrings("192.168.1.100", str);
}

test "create TCP socket" {
    const sock = try tcp();
    defer sock.close();
    try std.testing.expect(sock.getFd() >= 0);
}

test "create UDP socket" {
    const sock = try udp();
    defer sock.close();
    try std.testing.expect(sock.getFd() >= 0);
}

test "create socket with options" {
    const sock = try create(.tcp, .{
        .recv_timeout_ms = 5000,
        .tcp_nodelay = true,
    });
    defer sock.close();
    try std.testing.expect(sock.getFd() >= 0);
}
