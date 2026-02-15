//! Socket Interface Definition
//!
//! Provides a type-safe Socket interface with debug instrumentation.
//!
//! - Debug mode: Returns wrapper type with logging/profiling
//! - Release mode: Returns original type directly (zero overhead)
//!
//! Platform implementations:
//! - ESP32: lib/esp/src/sal/socket.zig
//! - Zig std: lib/std/src/sal/socket.zig
//!
//! Usage:
//! ```zig
//! pub fn Resolver(comptime SocketImpl: type) type {
//!     const Socket = sal.socket.Socket(SocketImpl);  // Get interface type
//!     return struct {
//!         pub fn resolve(self: *@This()) !void {
//!             var sock = try Socket.tcp();
//!             defer sock.close();
//!             // IDE has autocomplete for Socket methods!
//!         }
//!     };
//! }
//! ```

const std = @import("std");

/// IPv4 address
pub const Ipv4Address = [4]u8;

/// Socket error types
pub const Error = error{
    CreateFailed,
    BindFailed,
    BindToDeviceFailed,
    ConnectFailed,
    SendFailed,
    RecvFailed,
    Timeout,
    InvalidAddress,
    Closed,
    // Server-side errors
    ListenFailed,
    AcceptFailed,
};

/// UDP receive result with source address (for security validation)
pub const RecvFromResult = struct {
    len: usize,
    src_addr: Ipv4Address,
    src_port: u16,
};

/// Socket Interface - comptime validates and returns Impl
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types to avoid shallow copy
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };
        // Static methods
        _ = @as(*const fn () Error!BaseType, &BaseType.tcp);
        _ = @as(*const fn () Error!BaseType, &BaseType.udp);
        // Instance methods - basic operations
        _ = @as(*const fn (*BaseType) void, &BaseType.close);
        _ = @as(*const fn (*BaseType, Ipv4Address, u16) Error!void, &BaseType.connect);
        _ = @as(*const fn (*BaseType, []const u8) Error!usize, &BaseType.send);
        _ = @as(*const fn (*BaseType, []u8) Error!usize, &BaseType.recv);
        // Socket options
        _ = @as(*const fn (*BaseType, u32) void, &BaseType.setRecvTimeout);
        _ = @as(*const fn (*BaseType, u32) void, &BaseType.setSendTimeout);
        _ = @as(*const fn (*BaseType, bool) void, &BaseType.setTcpNoDelay);
        // UDP operations
        _ = @as(*const fn (*BaseType, Ipv4Address, u16, []const u8) Error!usize, &BaseType.sendTo);
        _ = @as(*const fn (*BaseType, []u8) Error!usize, &BaseType.recvFrom);
        if (!@hasDecl(BaseType, "recvFromWithAddr")) @compileError("Socket must implement recvFromWithAddr");
        // Server operations (UDP/TCP)
        _ = @as(*const fn (*BaseType, Ipv4Address, u16) Error!void, &BaseType.bind);
        _ = @as(*const fn (*BaseType) Error!u16, &BaseType.getBoundPort);
        // Async IO support
        _ = @as(*const fn (*BaseType) i32, &BaseType.getFd);
        _ = @as(*const fn (*BaseType, bool) Error!void, &BaseType.setNonBlocking);
    }
    return Impl;
}


/// Parse IPv4 address string (e.g., "192.168.1.1")
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

// =========== Tests ===========

test "parseIpv4" {
    const addr = parseIpv4("192.168.1.1").?;
    try std.testing.expectEqual(@as(u8, 192), addr[0]);
    try std.testing.expectEqual(@as(u8, 168), addr[1]);
    try std.testing.expectEqual(@as(u8, 1), addr[2]);
    try std.testing.expectEqual(@as(u8, 1), addr[3]);

    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4("invalid"));
    try std.testing.expectEqual(@as(?Ipv4Address, null), parseIpv4("256.1.1.1"));
}
