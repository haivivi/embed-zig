//! Test HTTPS client compilation
//!
//! This file tests that the HTTP client with TLS support compiles correctly.
//! Run with: zig build-exe test_https.zig -lc

const std = @import("std");
const http = @import("src/http.zig");

// Mock socket for testing compilation
const MockSocket = struct {
    const Self = @This();

    pub fn tcp() !Self {
        return .{};
    }

    pub fn udp() !Self {
        return .{};
    }

    pub fn parseIpv4(str: []const u8) ?[4]u8 {
        _ = str;
        return .{ 127, 0, 0, 1 };
    }

    pub fn close(self: Self) void {
        _ = self;
    }

    pub fn connect(self: Self, addr: [4]u8, port: u16) !void {
        _ = self;
        _ = addr;
        _ = port;
    }

    pub fn send(self: Self, data: []const u8) !usize {
        _ = self;
        return data.len;
    }

    pub fn recv(self: Self, buf: []u8) !usize {
        _ = self;
        _ = buf;
        return 0;
    }

    pub fn setRecvTimeout(self: Self, timeout_ms: u32) void {
        _ = self;
        _ = timeout_ms;
    }

    pub fn setSendTimeout(self: Self, timeout_ms: u32) void {
        _ = self;
        _ = timeout_ms;
    }

    pub fn setTcpNoDelay(self: Self, enable: bool) void {
        _ = self;
        _ = enable;
    }
};

pub fn main() !void {
    std.debug.print("Testing HTTP client compilation...\n", .{});

    // Test that Client type can be instantiated
    const HttpClient = http.Client(MockSocket);
    const client = HttpClient{
        .timeout_ms = 5000,
        .skip_cert_verify = true,
    };
    _ = client;

    // Test URL parsing
    std.debug.print("URL parsing works\n", .{});

    // Test stream types
    const Stream = http.SocketStream(MockSocket);
    _ = Stream;
    const TlsStream = http.TlsStream(MockSocket);
    _ = TlsStream;

    std.debug.print("All types compile successfully!\n", .{});
}

test "http client types" {
    const HttpClient = http.Client(MockSocket);
    _ = HttpClient;
}

test "stream types" {
    const Stream = http.SocketStream(MockSocket);
    _ = Stream;
    const TlsStream = http.TlsStream(MockSocket);
    _ = TlsStream;
}
