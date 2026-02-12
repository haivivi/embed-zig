//! LWIP BSD Socket Wrapper
//!
//! Provides idiomatic Zig wrapper for LWIP BSD sockets.

const std = @import("std");

const c = @cImport({
    @cInclude("lwip/sockets.h");
    @cInclude("lwip/netdb.h");
    @cInclude("errno.h");
});

// ============================================================================
// Types
// ============================================================================

/// IPv4 address (4 bytes)
pub const Ipv4Address = [4]u8;

/// IPv6 address (16 bytes)
pub const Ipv6Address = [16]u8;

/// Socket address
pub const Address = union(enum) {
    ipv4: Ipv4Address,
    ipv6: Ipv6Address,

    /// Format address as string.
    /// IPv4: "192.168.1.1", IPv6: "2001:db8:0:0:0:0:0:1"
    pub fn format(self: Address, buf: []u8) []const u8 {
        return switch (self) {
            .ipv4 => |addr| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                addr[0],
                addr[1],
                addr[2],
                addr[3],
            }) catch "?.?.?.?",
            .ipv6 => |addr| formatIpv6(buf, addr),
        };
    }

    /// Format IPv6 address as colon-hex groups (e.g. "2001:db8:0:0:0:0:0:1").
    fn formatIpv6(buf: []u8, addr: Ipv6Address) []const u8 {
        // 8 groups of 16-bit values, colon separated
        var groups: [8]u16 = undefined;
        for (0..8) |i| {
            groups[i] = @as(u16, addr[i * 2]) << 8 | @as(u16, addr[i * 2 + 1]);
        }
        return std.fmt.bufPrint(buf, "{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}", .{
            groups[0], groups[1], groups[2], groups[3],
            groups[4], groups[5], groups[6], groups[7],
        }) catch "?::?";
    }

    /// Parse IPv4 address string
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
};

/// Socket errors
pub const SocketError = error{
    CreateFailed,
    BindFailed,
    ListenFailed,
    AcceptFailed,
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
    recv_timeout_ms: u32 = 0,
    send_timeout_ms: u32 = 0,
    recv_buffer_size: u32 = 0,
    send_buffer_size: u32 = 0,
    tcp_nodelay: bool = false,
};

// ============================================================================
// Socket Implementation
// ============================================================================

pub const Socket = struct {
    fd: c_int,

    const Self = @This();

    /// Create a TCP socket (static method for DNS/HTTP compatibility)
    pub fn tcp() SocketError!Self {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
        if (fd < 0) return error.CreateFailed;
        return .{ .fd = fd };
    }

    /// Create a UDP socket (static method for DNS/HTTP compatibility)
    pub fn udp() SocketError!Self {
        const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
        if (fd < 0) return error.CreateFailed;
        return .{ .fd = fd };
    }

    /// Parse IPv4 address string (static method for HTTP compatibility)
    pub fn parseIpv4(str: []const u8) ?Ipv4Address {
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
        return addr;
    }

    /// Close the socket
    pub fn close(self: *Self) void {
        _ = c.close(self.fd);
    }

    // ============================================================================
    // Server Socket Functions
    // ============================================================================

    /// Bind socket to port (for server)
    pub fn bind(self: *Self, port: u16) SocketError!void {
        var sa: c.sockaddr_in = .{
            .sin_family = c.AF_INET,
            .sin_port = htons(port),
            .sin_addr = .{ .s_addr = 0 }, // INADDR_ANY
            .sin_zero = [_]u8{0} ** 8,
        };
        if (c.bind(self.fd, @ptrCast(&sa), @sizeOf(c.sockaddr_in)) < 0)
            return error.BindFailed;
    }

    /// Listen for incoming connections
    pub fn listen(self: *Self, backlog: u32) SocketError!void {
        if (c.listen(self.fd, @intCast(backlog)) < 0)
            return error.ListenFailed;
    }

    /// Accept incoming connection, returns new socket and client info
    pub fn accept(self: *Self) SocketError!struct { socket: Socket, addr: Ipv4Address, port: u16 } {
        var client_addr: c.sockaddr_in = undefined;
        var addr_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const client_fd = c.accept(self.fd, @ptrCast(&client_addr), &addr_len);
        if (client_fd < 0) {
            // Check if it's a timeout (non-blocking or timeout set)
            if (c.__errno().* == c.EAGAIN or c.__errno().* == c.EWOULDBLOCK) {
                return error.Timeout;
            }
            return error.AcceptFailed;
        }

        const s_addr = client_addr.sin_addr.s_addr;
        return .{
            .socket = .{ .fd = client_fd },
            .addr = .{
                @truncate(s_addr & 0xFF),
                @truncate((s_addr >> 8) & 0xFF),
                @truncate((s_addr >> 16) & 0xFF),
                @truncate((s_addr >> 24) & 0xFF),
            },
            .port = ntohs(client_addr.sin_port),
        };
    }

    /// Set socket to reuse address (useful for server)
    pub fn setReuseAddr(self: *Self, enable: bool) void {
        var val: c_int = if (enable) 1 else 0;
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_REUSEADDR, &val, @sizeOf(c_int));
    }

    // ============================================================================
    // Client Socket Functions
    // ============================================================================

    /// Connect to IPv4 address (simplified for DNS/HTTP)
    pub fn connect(self: *Self, addr: Ipv4Address, port: u16) SocketError!void {
        const sa = sockaddrIn(addr, port);
        const result = c.connect(self.fd, @ptrCast(&sa), @sizeOf(c.sockaddr_in));
        if (result < 0) return error.ConnectFailed;
    }

    /// Connect to Address union (for backward compatibility)
    pub fn connectAddr(self: *Self, addr: Address, port: u16) SocketError!void {
        const sa = switch (addr) {
            .ipv4 => |ipv4| sockaddrIn(ipv4, port),
            .ipv6 => return error.InvalidAddress, // TODO: IPv6 support
        };
        const result = c.connect(self.fd, @ptrCast(&sa), @sizeOf(c.sockaddr_in));
        if (result < 0) return error.ConnectFailed;
    }

    /// Send data (for connected socket)
    pub fn send(self: *Self, data: []const u8) SocketError!usize {
        const result = c.send(self.fd, data.ptr, data.len, 0);
        if (result < 0) return error.SendFailed;
        return @intCast(result);
    }

    /// Receive data
    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        const result = c.recv(self.fd, buf.ptr, buf.len, 0);
        if (result < 0) {
            if (c.__errno().* == c.EAGAIN or c.__errno().* == c.EWOULDBLOCK) {
                return error.Timeout;
            }
            return error.RecvFailed;
        }
        if (result == 0) return error.Closed;
        return @intCast(result);
    }

    /// Send data to IPv4 address (simplified for DNS)
    pub fn sendTo(self: *Self, addr: Ipv4Address, port: u16, data: []const u8) SocketError!usize {
        const sa = sockaddrIn(addr, port);
        const result = c.sendto(
            self.fd,
            data.ptr,
            data.len,
            0,
            @ptrCast(&sa),
            @sizeOf(c.sockaddr_in),
        );
        if (result < 0) return error.SendFailed;
        return @intCast(result);
    }

    /// Send data to Address union (backward compatibility)
    pub fn sendToAddr(self: *Self, addr: Address, port: u16, data: []const u8) SocketError!usize {
        const sa = switch (addr) {
            .ipv4 => |ipv4| sockaddrIn(ipv4, port),
            .ipv6 => return error.InvalidAddress,
        };
        const result = c.sendto(
            self.fd,
            data.ptr,
            data.len,
            0,
            @ptrCast(&sa),
            @sizeOf(c.sockaddr_in),
        );
        if (result < 0) return error.SendFailed;
        return @intCast(result);
    }

    /// Receive data from (simplified - just returns length)
    pub fn recvFrom(self: *Self, buf: []u8) SocketError!usize {
        var sa: c.sockaddr_in = undefined;
        var sa_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const result = c.recvfrom(
            self.fd,
            buf.ptr,
            buf.len,
            0,
            @ptrCast(&sa),
            &sa_len,
        );
        if (result < 0) {
            if (c.__errno().* == c.EAGAIN or c.__errno().* == c.EWOULDBLOCK) {
                return error.Timeout;
            }
            return error.RecvFailed;
        }
        if (result == 0) return error.Closed;
        return @intCast(result);
    }

    /// Receive data with sender info (for UDP)
    pub fn recvFromAddr(self: *Self, buf: []u8) SocketError!struct { len: usize, addr: Address, port: u16 } {
        var sa: c.sockaddr_in = undefined;
        var sa_len: c.socklen_t = @sizeOf(c.sockaddr_in);
        const result = c.recvfrom(
            self.fd,
            buf.ptr,
            buf.len,
            0,
            @ptrCast(&sa),
            &sa_len,
        );
        if (result < 0) {
            if (c.__errno().* == c.EAGAIN or c.__errno().* == c.EWOULDBLOCK) {
                return error.Timeout;
            }
            return error.RecvFailed;
        }
        if (result == 0) return error.Closed;

        const s_addr = sa.sin_addr.s_addr;
        return .{
            .len = @intCast(result),
            .addr = .{ .ipv4 = .{
                @truncate(s_addr & 0xFF),
                @truncate((s_addr >> 8) & 0xFF),
                @truncate((s_addr >> 16) & 0xFF),
                @truncate((s_addr >> 24) & 0xFF),
            } },
            .port = ntohs(sa.sin_port),
        };
    }

    /// Set socket options (batch)
    pub fn setOptions(self: *Self, options: Options) void {
        if (options.recv_timeout_ms > 0) self.setRecvTimeout(options.recv_timeout_ms);
        if (options.send_timeout_ms > 0) self.setSendTimeout(options.send_timeout_ms);
        if (options.recv_buffer_size > 0) {
            var val: c_int = @intCast(options.recv_buffer_size);
            _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_RCVBUF, &val, @sizeOf(c_int));
        }
        if (options.send_buffer_size > 0) {
            var val: c_int = @intCast(options.send_buffer_size);
            _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDBUF, &val, @sizeOf(c_int));
        }
        if (options.tcp_nodelay) self.setTcpNoDelay(true);
    }

    /// Set receive timeout
    pub fn setRecvTimeout(self: *Self, timeout_ms: u32) void {
        const tv = timeval(timeout_ms);
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.timeval));
    }

    /// Set send timeout
    pub fn setSendTimeout(self: *Self, timeout_ms: u32) void {
        const tv = timeval(timeout_ms);
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.timeval));
    }

    /// Enable/disable TCP_NODELAY
    pub fn setTcpNoDelay(self: *Self, enable: bool) void {
        var val: c_int = if (enable) 1 else 0;
        _ = c.setsockopt(self.fd, c.IPPROTO_TCP, c.TCP_NODELAY, &val, @sizeOf(c_int));
    }

    /// Bind socket to a specific network interface
    pub fn bindToDevice(self: *Self, interface_name: []const u8) SocketError!void {
        var ifr: c.ifreq = std.mem.zeroes(c.ifreq);
        const name_len = @min(interface_name.len, ifr.ifr_name.len - 1);
        @memcpy(ifr.ifr_name[0..name_len], interface_name[0..name_len]);

        const result = c.setsockopt(
            self.fd,
            c.SOL_SOCKET,
            c.SO_BINDTODEVICE,
            &ifr,
            @sizeOf(c.ifreq),
        );
        if (result < 0) return error.BindToDeviceFailed;
    }

    /// Get the underlying file descriptor
    pub fn getFd(self: *Self) c_int {
        return self.fd;
    }

    // Helper functions
    fn sockaddrIn(addr: Ipv4Address, port: u16) c.sockaddr_in {
        return .{
            .sin_family = c.AF_INET,
            .sin_port = htons(port),
            .sin_addr = .{
                .s_addr = @as(u32, addr[0]) |
                    (@as(u32, addr[1]) << 8) |
                    (@as(u32, addr[2]) << 16) |
                    (@as(u32, addr[3]) << 24),
            },
            .sin_zero = [_]u8{0} ** 8,
        };
    }

    fn htons(v: u16) u16 {
        return @byteSwap(v);
    }

    fn ntohs(v: u16) u16 {
        return @byteSwap(v);
    }

    fn timeval(ms: u32) c.timeval {
        return .{
            .tv_sec = @intCast(ms / 1000),
            .tv_usec = @intCast((ms % 1000) * 1000),
        };
    }
};

// ============================================================================
// Socket Creation Functions
// ============================================================================

/// Create a TCP socket
pub fn tcp() SocketError!Socket {
    const fd = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
    if (fd < 0) return error.CreateFailed;
    return .{ .fd = fd };
}

/// Create a UDP socket
pub fn udp() SocketError!Socket {
    const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
    if (fd < 0) return error.CreateFailed;
    return .{ .fd = fd };
}

/// Create a socket with options
pub fn create(protocol: Protocol, options: Options) SocketError!Socket {
    var sock = switch (protocol) {
        .tcp => try tcp(),
        .udp => try udp(),
    };
    sock.setOptions(options);
    return sock;
}
