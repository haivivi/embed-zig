//! HTTPS Connection Test
//!
//! Test the pure Zig TLS library by connecting to real HTTPS servers.
//! Run with: zig build test-https

const std = @import("std");
const tls = @import("tls");
const trait = @import("trait");

// Use std.crypto.random for RNG
const StdRng = struct {
    pub fn fill(buf: []u8) void {
        std.crypto.random.bytes(buf);
    }
};

// Mock socket for testing (real implementation would use std.net)
const MockSocket = struct {
    tcp_stream: ?std.net.Stream,

    pub fn tcp() !MockSocket {
        return MockSocket{ .tcp_stream = null };
    }

    pub fn connect(self: *MockSocket, addr: [4]u8, port: u16) !void {
        const ip_str = std.fmt.allocPrint(
            std.heap.page_allocator,
            "{d}.{d}.{d}.{d}",
            .{ addr[0], addr[1], addr[2], addr[3] },
        ) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(ip_str);

        const address = std.net.Address.parseIp4(ip_str, port) catch {
            return error.InvalidAddress;
        };
        self.tcp_stream = std.net.tcpConnectToAddress(address) catch {
            return error.ConnectionFailed;
        };
    }

    pub fn close(self: *MockSocket) void {
        if (self.tcp_stream) |stream| {
            stream.close();
        }
    }

    pub fn send(self: *MockSocket, data: []const u8) !usize {
        if (self.tcp_stream) |stream| {
            return stream.write(data);
        }
        return error.NotConnected;
    }

    pub fn recv(self: *MockSocket, buf: []u8) !usize {
        if (self.tcp_stream) |stream| {
            return stream.read(buf);
        }
        return error.NotConnected;
    }

    pub fn setRecvTimeout(_: *MockSocket, _: u32) void {}
    pub fn setSendTimeout(_: *MockSocket, _: u32) void {}
    pub fn setTcpNoDelay(_: *MockSocket, _: bool) void {}

    pub fn parseIpv4(s: []const u8) ?[4]u8 {
        const addr = std.net.Address.parseIp4(s, 0) catch return null;
        return addr.in.sa.addr;
    }
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("Pure Zig TLS Library Test\n", .{});
    std.debug.print("==========================\n\n", .{});

    // Test 1: Basic handshake test
    std.debug.print("Test 1: TLS Handshake with example.com\n", .{});

    // Resolve hostname (using hardcoded IP for simplicity)
    // example.com -> 93.184.216.34
    const example_com_ip = [4]u8{ 93, 184, 216, 34 };

    var socket = try MockSocket.tcp();
    defer socket.close();

    std.debug.print("  Connecting to 93.184.216.34:443...\n", .{});
    try socket.connect(example_com_ip, 443);
    std.debug.print("  TCP connected.\n", .{});

    // Initialize TLS client
    var client = try tls.Client(MockSocket, StdRng).init(&socket, .{
        .allocator = allocator,
        .hostname = "example.com",
        .skip_verify = true, // Skip cert verification for testing
    });
    defer client.deinit();

    std.debug.print("  Starting TLS handshake...\n", .{});
    client.connect() catch |err| {
        std.debug.print("  TLS handshake failed: {}\n", .{err});
        return;
    };

    std.debug.print("  TLS handshake completed!\n", .{});
    std.debug.print("  Protocol: {s}\n", .{client.getVersion().name()});
    std.debug.print("  Cipher Suite: 0x{x:0>4}\n", .{@intFromEnum(client.getCipherSuite())});

    // Send HTTP request
    const request = "GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n";
    std.debug.print("\n  Sending HTTP request...\n", .{});
    _ = try client.send(request);

    // Receive response
    var buffer: [4096]u8 = undefined;
    const n = try client.recv(&buffer);

    std.debug.print("  Received {d} bytes\n", .{n});
    std.debug.print("\n  Response (first 500 chars):\n", .{});

    const preview_len = @min(n, 500);
    std.debug.print("{s}\n", .{buffer[0..preview_len]});

    std.debug.print("\n==========================\n", .{});
    std.debug.print("Test completed successfully!\n", .{});
}

test "TLS common types" {
    // Basic sanity tests
    try std.testing.expectEqual(@as(u16, 0x0303), @intFromEnum(tls.ProtocolVersion.tls_1_2));
    try std.testing.expectEqual(@as(u16, 0x0304), @intFromEnum(tls.ProtocolVersion.tls_1_3));
}
