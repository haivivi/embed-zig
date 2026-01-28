//! TLS Interface Definition
//!
//! Provides compile-time validation for TLS interface.
//!
//! Platform implementations:
//! - ESP32: lib/esp/src/sal/tls.zig (mbedTLS)
//! - Zig std: lib/std/src/sal/tls.zig

const std = @import("std");
const socket = @import("socket.zig");

/// TLS error types
pub const Error = error{
    InitFailed,
    HandshakeFailed,
    CertificateError,
    SendFailed,
    RecvFailed,
    Timeout,
    ConnectionClosed,
    OutOfMemory,
};

/// TLS configuration options
pub const Options = struct {
    skip_cert_verify: bool = false,
    timeout_ms: u32 = 30000,
};

/// TLS Interface - comptime validates and returns Impl
pub fn from(comptime Impl: type) type {
    comptime {
        // Handle pointer types to avoid shallow copy
        const BaseType = switch (@typeInfo(Impl)) {
            .pointer => |p| p.child,
            else => Impl,
        };

        // Mock socket for init validation (hidden inside comptime)
        var mock_socket: socket.from(struct {
            pub fn tcp() socket.Error!@This() { return .{}; }
            pub fn udp() socket.Error!@This() { return .{}; }
            pub fn close(_: *@This()) void {}
            pub fn connect(_: *@This(), _: socket.Ipv4Address, _: u16) socket.Error!void {}
            pub fn send(_: *@This(), _: []const u8) socket.Error!usize { return 0; }
            pub fn recv(_: *@This(), _: []u8) socket.Error!usize { return 0; }
            pub fn setRecvTimeout(_: *@This(), _: u32) void {}
            pub fn setSendTimeout(_: *@This(), _: u32) void {}
            pub fn setTcpNoDelay(_: *@This(), _: bool) void {}
            pub fn sendTo(_: *@This(), _: socket.Ipv4Address, _: u16, _: []const u8) socket.Error!usize { return 0; }
            pub fn recvFrom(_: *@This(), _: []u8) socket.Error!usize { return 0; }
        }) = undefined;

        _ = BaseType.init(&mock_socket, Options{}) catch {};

        // Instance methods
        _ = @as(*const fn (*BaseType, []const u8) Error!void, &BaseType.handshake);
        _ = @as(*const fn (*BaseType, []const u8) Error!usize, &BaseType.send);
        _ = @as(*const fn (*BaseType, []u8) Error!usize, &BaseType.recv);
        _ = @as(*const fn (*BaseType) void, &BaseType.deinit);
    }
    return Impl;
}

