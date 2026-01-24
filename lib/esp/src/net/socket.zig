//! Low-level socket wrapper with interface binding support

const std = @import("std");

const c = @cImport({
    @cInclude("lwip/sockets.h");
    @cInclude("lwip/netdb.h");
    @cInclude("errno.h");
});

pub const Ipv4Address = [4]u8;

/// Parse IPv4 address string (e.g., "192.168.1.1") to bytes
pub fn parseIpv4(ip_str: []const u8) ?Ipv4Address {
    var buf: [16]u8 = undefined;
    if (ip_str.len >= buf.len) return null;
    @memcpy(buf[0..ip_str.len], ip_str);
    buf[ip_str.len] = 0;

    var addr: c.in_addr = undefined;
    if (c.inet_pton(c.AF_INET, &buf, &addr) != 1) {
        return null;
    }

    const s_addr = addr.s_addr;
    return .{
        @truncate(s_addr & 0xFF),
        @truncate((s_addr >> 8) & 0xFF),
        @truncate((s_addr >> 16) & 0xFF),
        @truncate((s_addr >> 24) & 0xFF),
    };
}

pub const SocketError = error{
    CreateFailed,
    BindFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    InvalidAddress,
    BindToDeviceFailed,
};

pub const Socket = struct {
    fd: c_int,

    const Self = @This();

    /// Create a UDP socket
    pub fn udp() SocketError!Self {
        const fd = c.socket(c.AF_INET, c.SOCK_DGRAM, c.IPPROTO_UDP);
        if (fd < 0) return error.CreateFailed;
        return .{ .fd = fd };
    }

    /// Create a TCP socket
    pub fn tcp() SocketError!Self {
        const fd = c.socket(c.AF_INET, c.SOCK_STREAM, c.IPPROTO_TCP);
        if (fd < 0) return error.CreateFailed;
        return .{ .fd = fd };
    }

    /// Close the socket
    pub fn close(self: Self) void {
        _ = c.close(self.fd);
    }

    /// Bind socket to a specific network interface (e.g., "ppp0", "wlan0")
    pub fn bindToDevice(self: Self, interface_name: []const u8) SocketError!void {
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

    /// Set receive timeout
    pub fn setRecvTimeout(self: Self, timeout_ms: u32) void {
        const tv = c.timeval{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_RCVTIMEO, &tv, @sizeOf(c.timeval));
    }

    /// Set send timeout
    pub fn setSendTimeout(self: Self, timeout_ms: u32) void {
        const tv = c.timeval{
            .tv_sec = @intCast(timeout_ms / 1000),
            .tv_usec = @intCast((timeout_ms % 1000) * 1000),
        };
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDTIMEO, &tv, @sizeOf(c.timeval));
    }

    /// Enable TCP_NODELAY (disable Nagle's algorithm)
    pub fn setTcpNoDelay(self: Self, enable: bool) void {
        var val: c_int = if (enable) 1 else 0;
        _ = c.setsockopt(self.fd, c.IPPROTO_TCP, c.TCP_NODELAY, &val, @sizeOf(c_int));
    }

    /// Set receive buffer size
    pub fn setRecvBufferSize(self: Self, size: u32) void {
        var val: c_int = @intCast(size);
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_RCVBUF, &val, @sizeOf(c_int));
    }

    /// Set send buffer size
    pub fn setSendBufferSize(self: Self, size: u32) void {
        var val: c_int = @intCast(size);
        _ = c.setsockopt(self.fd, c.SOL_SOCKET, c.SO_SNDBUF, &val, @sizeOf(c_int));
    }

    /// Connect to an address (for TCP)
    pub fn connect(self: Self, addr: Ipv4Address, port: u16) SocketError!void {
        var sa = sockaddrIn(addr, port);
        const result = c.connect(self.fd, @ptrCast(&sa), @sizeOf(c.sockaddr_in));
        if (result < 0) return error.ConnectFailed;
    }

    /// Send data to a specific address (for UDP)
    pub fn sendTo(self: Self, addr: Ipv4Address, port: u16, data: []const u8) SocketError!usize {
        var sa = sockaddrIn(addr, port);
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

    /// Send data (for connected socket)
    pub fn send(self: Self, data: []const u8) SocketError!usize {
        const result = c.send(self.fd, data.ptr, data.len, 0);
        if (result < 0) return error.SendFailed;
        return @intCast(result);
    }

    /// Receive data
    pub fn recv(self: Self, buf: []u8) SocketError!usize {
        const result = c.recv(self.fd, buf.ptr, buf.len, 0);
        if (result < 0) {
            if (c.__errno().* == c.EAGAIN or c.__errno().* == c.EWOULDBLOCK) {
                return error.Timeout;
            }
            return error.RecvFailed;
        }
        return @intCast(result);
    }

    /// Receive data from (for UDP)
    pub fn recvFrom(self: Self, buf: []u8) SocketError!usize {
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
        return @intCast(result);
    }

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
};
