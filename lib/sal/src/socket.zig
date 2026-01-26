//! Socket Abstraction
//!
//! Provides cross-platform socket interface for TCP/UDP communication.
//!
//! Platform implementations should provide:
//!   - TCP and UDP socket creation
//!   - Connect, send, receive operations
//!   - Socket options (timeout, buffer sizes)
//!
//! Example:
//!   // Create TCP socket
//!   var sock = try sal.socket.tcp();
//!   defer sock.close();
//!
//!   // Connect and send
//!   try sock.connect(.{ .ipv4 = .{ 192, 168, 1, 1 } }, 80);
//!   _ = try sock.send("GET / HTTP/1.0\r\n\r\n");
//!
//!   // Receive
//!   var buf: [1024]u8 = undefined;
//!   const n = try sock.recv(&buf);

const std = @import("std");

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

/// Socket handle - opaque, platform-specific
pub const Socket = struct {
    /// Platform-specific implementation data
    impl: *anyopaque,

    const Self = @This();

    /// Close the socket
    pub fn close(self: Self) void {
        _ = self;
        @compileError("sal.socket.Socket.close requires platform implementation");
    }

    /// Connect to an address (for TCP)
    pub fn connect(self: Self, addr: Address, port: u16) SocketError!void {
        _ = self;
        _ = addr;
        _ = port;
        @compileError("sal.socket.Socket.connect requires platform implementation");
    }

    /// Send data (for connected socket)
    pub fn send(self: Self, data: []const u8) SocketError!usize {
        _ = self;
        _ = data;
        @compileError("sal.socket.Socket.send requires platform implementation");
    }

    /// Receive data
    pub fn recv(self: Self, buf: []u8) SocketError!usize {
        _ = self;
        _ = buf;
        @compileError("sal.socket.Socket.recv requires platform implementation");
    }

    /// Send data to a specific address (for UDP)
    pub fn sendTo(self: Self, addr: Address, port: u16, data: []const u8) SocketError!usize {
        _ = self;
        _ = addr;
        _ = port;
        _ = data;
        @compileError("sal.socket.Socket.sendTo requires platform implementation");
    }

    /// Receive data from (for UDP), returns sender address
    pub fn recvFrom(self: Self, buf: []u8) SocketError!struct { len: usize, addr: Address, port: u16 } {
        _ = self;
        _ = buf;
        @compileError("sal.socket.Socket.recvFrom requires platform implementation");
    }

    /// Set socket options
    pub fn setOptions(self: Self, options: Options) void {
        _ = self;
        _ = options;
        @compileError("sal.socket.Socket.setOptions requires platform implementation");
    }

    /// Bind socket to a specific network interface (e.g., "ppp0", "wlan0")
    pub fn bindToDevice(self: Self, interface_name: []const u8) SocketError!void {
        _ = self;
        _ = interface_name;
        @compileError("sal.socket.Socket.bindToDevice requires platform implementation");
    }

    /// Get the underlying file descriptor (platform-specific)
    pub fn getFd(self: Self) i32 {
        _ = self;
        @compileError("sal.socket.Socket.getFd requires platform implementation");
    }
};

/// Create a TCP socket
pub fn tcp() SocketError!Socket {
    @compileError("sal.socket.tcp requires platform implementation");
}

/// Create a UDP socket
pub fn udp() SocketError!Socket {
    @compileError("sal.socket.udp requires platform implementation");
}

/// Create a socket with options
pub fn create(protocol: Protocol, options: Options) SocketError!Socket {
    _ = protocol;
    _ = options;
    @compileError("sal.socket.create requires platform implementation");
}
