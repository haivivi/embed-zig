//! LWIP BSD Socket Wrapper for BK7258
//!
//! Matches the ESP socket.zig interface exactly so that cross-platform
//! code (lib/pkg/dns, lib/pkg/http, etc.) works unchanged.

const std = @import("std");
const trait_socket = @import("trait").socket;

// C helper functions (bk_zig_socket_helper.c)
extern fn bk_zig_socket_tcp() c_int;
extern fn bk_zig_socket_udp() c_int;
extern fn bk_zig_socket_close(fd: c_int) void;
extern fn bk_zig_socket_connect(fd: c_int, ip_be: u32, port: u16) c_int;
extern fn bk_zig_socket_send(fd: c_int, data: [*]const u8, len: u32) c_int;
extern fn bk_zig_socket_recv(fd: c_int, buf: [*]u8, len: u32) c_int;
extern fn bk_zig_socket_sendto(fd: c_int, ip_be: u32, port: u16, data: [*]const u8, len: u32) c_int;
extern fn bk_zig_socket_recvfrom(fd: c_int, buf: [*]u8, len: u32, out_ip: *u32, out_port: *u16) c_int;
extern fn bk_zig_socket_bind(fd: c_int, port: u16) c_int;
extern fn bk_zig_socket_listen(fd: c_int, backlog: c_int) c_int;
extern fn bk_zig_socket_accept(fd: c_int, out_ip: *u32, out_port: *u16) c_int;
extern fn bk_zig_socket_set_recv_timeout(fd: c_int, ms: u32) c_int;
extern fn bk_zig_socket_set_send_timeout(fd: c_int, ms: u32) c_int;
extern fn bk_zig_socket_set_reuse_addr(fd: c_int, enable: c_int) c_int;
extern fn bk_zig_socket_set_nodelay(fd: c_int, enable: c_int) c_int;
extern fn bk_zig_socket_set_nonblocking(fd: c_int, enable: c_int) c_int;
extern fn bk_zig_socket_get_bound_port(fd: c_int) c_int;

// ============================================================================
// Types (identical to ESP)
// ============================================================================

pub const Ipv4Address = [4]u8;
pub const Ipv6Address = [16]u8;

pub const Address = union(enum) {
    ipv4: Ipv4Address,
    ipv6: Ipv6Address,

    pub fn format(self: Address, buf: []u8) []const u8 {
        return switch (self) {
            .ipv4 => |addr| std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
                addr[0], addr[1], addr[2], addr[3],
            }) catch "?.?.?.?",
            .ipv6 => "ipv6",
        };
    }
};

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

pub const Protocol = enum { tcp, udp };

pub const Options = struct {
    recv_timeout_ms: u32 = 0,
    send_timeout_ms: u32 = 0,
    recv_buffer_size: u32 = 0,
    send_buffer_size: u32 = 0,
    tcp_nodelay: bool = false,
};

// ============================================================================
// Socket Implementation (same API as ESP)
// ============================================================================

pub const Socket = struct {
    fd: c_int,

    const Self = @This();

    pub fn tcp() SocketError!Self {
        const fd = bk_zig_socket_tcp();
        if (fd < 0) return error.CreateFailed;
        return .{ .fd = fd };
    }

    pub fn udp() SocketError!Self {
        const fd = bk_zig_socket_udp();
        if (fd < 0) return error.CreateFailed;
        return .{ .fd = fd };
    }

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
            } else return null;
        }
        if (dots != 3 or idx != 3) return null;
        addr[3] = @intCast(num);
        return addr;
    }

    pub fn close(self: *Self) void {
        bk_zig_socket_close(self.fd);
    }

    // === Client ===

    pub fn connect(self: *Self, addr: Ipv4Address, port: u16) SocketError!void {
        const ip_be = ipv4ToBe(addr);
        if (bk_zig_socket_connect(self.fd, ip_be, port) < 0)
            return error.ConnectFailed;
    }

    pub fn connectAddr(self: *Self, addr: Address, port: u16) SocketError!void {
        switch (addr) {
            .ipv4 => |ipv4| try self.connect(ipv4, port),
            .ipv6 => return error.InvalidAddress,
        }
    }

    pub fn send(self: *Self, data: []const u8) SocketError!usize {
        const result = bk_zig_socket_send(self.fd, data.ptr, @intCast(data.len));
        if (result < 0) return error.SendFailed;
        return @intCast(result);
    }

    pub fn recv(self: *Self, buf: []u8) SocketError!usize {
        const result = bk_zig_socket_recv(self.fd, buf.ptr, @intCast(buf.len));
        if (result < 0) return error.Timeout; // simplified: any error = timeout
        if (result == 0) return error.Closed;
        return @intCast(result);
    }

    // === UDP ===

    pub fn sendTo(self: *Self, addr: Ipv4Address, port: u16, data: []const u8) SocketError!usize {
        const ip_be = ipv4ToBe(addr);
        const result = bk_zig_socket_sendto(self.fd, ip_be, port, data.ptr, @intCast(data.len));
        if (result < 0) return error.SendFailed;
        return @intCast(result);
    }

    pub fn sendToAddr(self: *Self, addr: Address, port: u16, data: []const u8) SocketError!usize {
        switch (addr) {
            .ipv4 => |ipv4| return self.sendTo(ipv4, port, data),
            .ipv6 => return error.InvalidAddress,
        }
    }

    pub fn recvFrom(self: *Self, buf: []u8) SocketError!usize {
        var ip_be: u32 = 0;
        var port: u16 = 0;
        const result = bk_zig_socket_recvfrom(self.fd, buf.ptr, @intCast(buf.len), &ip_be, &port);
        if (result < 0) return error.Timeout;
        if (result == 0) return error.Closed;
        return @intCast(result);
    }

    pub fn recvFromWithAddr(self: *Self, buf: []u8) SocketError!trait_socket.RecvFromResult {
        var ip_be: u32 = 0;
        var port: u16 = 0;
        const result = bk_zig_socket_recvfrom(self.fd, buf.ptr, @intCast(buf.len), &ip_be, &port);
        if (result < 0) return error.Timeout;
        if (result == 0) return error.Closed;
        return .{
            .len = @intCast(result),
            .src_addr = beToIpv4(ip_be),
            .src_port = port,
        };
    }

    // === Server ===

    pub fn bind(self: *Self, _: Ipv4Address, port: u16) SocketError!void {
        if (bk_zig_socket_bind(self.fd, port) < 0) return error.BindFailed;
    }

    pub fn getBoundPort(self: *Self) SocketError!u16 {
        const port = bk_zig_socket_get_bound_port(self.fd);
        if (port < 0) return error.BindFailed;
        return @intCast(port);
    }

    pub fn listen(self: *Self, backlog: u32) SocketError!void {
        if (bk_zig_socket_listen(self.fd, @intCast(backlog)) < 0) return error.ListenFailed;
    }

    pub fn accept(self: *Self) SocketError!struct { socket: Socket, addr: Ipv4Address, port: u16 } {
        var ip_be: u32 = 0;
        var port: u16 = 0;
        const fd = bk_zig_socket_accept(self.fd, &ip_be, &port);
        if (fd < 0) return error.AcceptFailed;
        return .{
            .socket = .{ .fd = fd },
            .addr = beToIpv4(ip_be),
            .port = port,
        };
    }

    pub fn setReuseAddr(self: *Self, enable: bool) void {
        _ = bk_zig_socket_set_reuse_addr(self.fd, if (enable) 1 else 0);
    }

    // === Options ===

    pub fn setOptions(self: *Self, options: Options) void {
        if (options.recv_timeout_ms > 0) self.setRecvTimeout(options.recv_timeout_ms);
        if (options.send_timeout_ms > 0) self.setSendTimeout(options.send_timeout_ms);
        if (options.tcp_nodelay) self.setTcpNoDelay(true);
    }

    pub fn setRecvTimeout(self: *Self, timeout_ms: u32) void {
        _ = bk_zig_socket_set_recv_timeout(self.fd, timeout_ms);
    }

    pub fn setSendTimeout(self: *Self, timeout_ms: u32) void {
        _ = bk_zig_socket_set_send_timeout(self.fd, timeout_ms);
    }

    pub fn setTcpNoDelay(self: *Self, enable: bool) void {
        _ = bk_zig_socket_set_nodelay(self.fd, if (enable) 1 else 0);
    }

    pub fn setNonBlocking(self: *Self, non_blocking: bool) SocketError!void {
        if (bk_zig_socket_set_nonblocking(self.fd, if (non_blocking) 1 else 0) < 0)
            return error.CreateFailed;
    }

    pub fn getFd(self: *Self) c_int {
        return self.fd;
    }

    // === Helpers ===

    fn ipv4ToBe(addr: Ipv4Address) u32 {
        return @as(u32, addr[0]) |
            (@as(u32, addr[1]) << 8) |
            (@as(u32, addr[2]) << 16) |
            (@as(u32, addr[3]) << 24);
    }

    fn beToIpv4(ip_be: u32) Ipv4Address {
        return .{
            @truncate(ip_be & 0xFF),
            @truncate((ip_be >> 8) & 0xFF),
            @truncate((ip_be >> 16) & 0xFF),
            @truncate((ip_be >> 24) & 0xFF),
        };
    }
};

// ============================================================================
// Top-level creation functions (matching ESP)
// ============================================================================

pub fn tcp() SocketError!Socket {
    return Socket.tcp();
}

pub fn udp() SocketError!Socket {
    return Socket.udp();
}

pub fn create(protocol: Protocol, options: Options) SocketError!Socket {
    var sock = switch (protocol) {
        .tcp => try tcp(),
        .udp => try udp(),
    };
    sock.setOptions(options);
    return sock;
}
