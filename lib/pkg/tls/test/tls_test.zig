//! TLS Client Tests
//!
//! Integration tests for the pure Zig TLS client.
//! Requires the Go test server to be running.

const std = @import("std");
const tls = @import("tls");
const crypto = @import("crypto");

// Standard library TCP socket wrapper
const StdSocket = struct {
    stream: ?std.net.Stream,

    const Self = @This();
    const Error = error{
        ConnectionFailed,
        NotConnected,
        SendFailed,
        RecvFailed,
        Timeout,
        Closed,
    };

    pub fn tcp() !Self {
        return Self{ .stream = null };
    }

    pub fn connect(self: *Self, addr: [4]u8, port: u16) !void {
        const address = std.net.Address.initIp4(addr, port);
        self.stream = std.net.tcpConnectToAddress(address) catch {
            return error.ConnectionFailed;
        };
    }

    pub fn close(self: *Self) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
    }

    pub fn send(self: *Self, data: []const u8) Error!usize {
        if (self.stream) |s| {
            return s.write(data) catch error.SendFailed;
        }
        return error.NotConnected;
    }

    pub fn recv(self: *Self, buf: []u8) Error!usize {
        if (self.stream) |s| {
            const n = s.read(buf) catch return error.RecvFailed;
            if (n == 0) return error.Closed;
            return n;
        }
        return error.NotConnected;
    }

    pub fn setRecvTimeout(_: *Self, _: u32) void {}
    pub fn setSendTimeout(_: *Self, _: u32) void {}
    pub fn setTcpNoDelay(_: *Self, _: bool) void {}

    pub fn parseIpv4(s: []const u8) ?[4]u8 {
        var result: [4]u8 = undefined;
        var i: usize = 0;
        var octet: u8 = 0;
        var octet_idx: usize = 0;

        for (s) |c| {
            if (c == '.') {
                if (octet_idx >= 4) return null;
                result[octet_idx] = octet;
                octet_idx += 1;
                octet = 0;
            } else if (c >= '0' and c <= '9') {
                octet = octet * 10 + (c - '0');
            } else {
                return null;
            }
            i += 1;
        }

        if (octet_idx == 3) {
            result[3] = octet;
            return result;
        }
        return null;
    }
};

/// Runtime with std.Thread.Mutex for thread safety
const StdRuntime = struct {
    pub const Mutex = struct {
        inner: std.Thread.Mutex = .{},
        pub fn init() Mutex {
            return .{};
        }
        pub fn deinit(_: *Mutex) void {}
        pub fn lock(self: *Mutex) void {
            self.inner.lock();
        }
        pub fn unlock(self: *Mutex) void {
            self.inner.unlock();
        }
    };
};

const TestClient = tls.Client(StdSocket, crypto, StdRuntime);

/// Test configuration
const TestConfig = struct {
    name: []const u8,
    port: u16,
    expected_version: tls.ProtocolVersion,
};

const test_cases = [_]TestConfig{
    // TLS 1.3 tests
    .{ .name = "tls13_aes128gcm", .port = 8443, .expected_version = .tls_1_3 },
    .{ .name = "tls13_aes256gcm", .port = 8444, .expected_version = .tls_1_3 },
    .{ .name = "tls13_chacha20", .port = 8445, .expected_version = .tls_1_3 },

    // TLS 1.2 ECDSA tests
    .{ .name = "tls12_ecdhe_ecdsa_aes128", .port = 8446, .expected_version = .tls_1_2 },
    .{ .name = "tls12_ecdhe_ecdsa_aes256", .port = 8447, .expected_version = .tls_1_2 },
    .{ .name = "tls12_ecdhe_ecdsa_chacha20", .port = 8448, .expected_version = .tls_1_2 },

    // TLS 1.2 RSA tests
    .{ .name = "tls12_ecdhe_rsa_aes128", .port = 8449, .expected_version = .tls_1_2 },
    .{ .name = "tls12_ecdhe_rsa_aes256", .port = 8450, .expected_version = .tls_1_2 },
    .{ .name = "tls12_ecdhe_rsa_chacha20", .port = 8451, .expected_version = .tls_1_2 },
};

fn runTest(config: TestConfig) !void {
    const allocator = std.testing.allocator;

    std.debug.print("\n[TEST] {s} (port {d})\n", .{ config.name, config.port });

    // Connect to localhost
    var socket = try StdSocket.tcp();
    defer socket.close();

    socket.connect([4]u8{ 127, 0, 0, 1 }, config.port) catch |err| {
        std.debug.print("  SKIP: Server not available ({any})\n", .{err});
        return;
    };

    // Initialize TLS client
    var client = try TestClient.init(&socket, .{
        .allocator = allocator,
        .hostname = "localhost",
        .skip_verify = true, // Self-signed cert
    });
    defer client.deinit();

    // Perform handshake
    client.connect() catch |err| {
        std.debug.print("  FAIL: Handshake failed ({any})\n", .{err});
        return err;
    };

    // Verify version
    const version = client.getVersion();
    std.debug.print("  Version: {s} (0x{x:0>4})\n", .{ version.name(), @intFromEnum(version) });

    if (version != config.expected_version) {
        std.debug.print("  FAIL: Expected version {s}\n", .{config.expected_version.name()});
        return error.VersionMismatch;
    }

    // Send test request
    const request = "GET /test HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    _ = try client.send(request);

    // Receive response
    var buffer: [4096]u8 = undefined;
    var total: usize = 0;

    while (true) {
        const n = client.recv(buffer[total..]) catch |err| {
            if (err == error.ConnectionClosed and total > 0) break;
            return err;
        };
        if (n == 0) break;
        total += n;
    }

    // Verify response
    const response = buffer[0..total];
    if (std.mem.indexOf(u8, response, "200 OK") == null) {
        std.debug.print("  FAIL: Unexpected response\n", .{});
        return error.BadResponse;
    }

    if (std.mem.indexOf(u8, response, "\"ok\":true") == null) {
        std.debug.print("  FAIL: Test not OK\n", .{});
        return error.TestFailed;
    }

    std.debug.print("  PASS\n", .{});
}

// Individual test functions for Bazel test runner
test "TLS 1.3 AES-128-GCM" {
    try runTest(test_cases[0]);
}

test "TLS 1.3 AES-256-GCM" {
    try runTest(test_cases[1]);
}

test "TLS 1.3 ChaCha20-Poly1305" {
    try runTest(test_cases[2]);
}

test "TLS 1.2 ECDHE-ECDSA AES-128-GCM" {
    try runTest(test_cases[3]);
}

test "TLS 1.2 ECDHE-ECDSA AES-256-GCM" {
    try runTest(test_cases[4]);
}

test "TLS 1.2 ECDHE-ECDSA ChaCha20-Poly1305" {
    try runTest(test_cases[5]);
}

test "TLS 1.2 ECDHE-RSA AES-128-GCM" {
    try runTest(test_cases[6]);
}

test "TLS 1.2 ECDHE-RSA AES-256-GCM" {
    try runTest(test_cases[7]);
}

test "TLS 1.2 ECDHE-RSA ChaCha20-Poly1305" {
    try runTest(test_cases[8]);
}

/// Main entry point for manual testing
pub fn main() !void {
    std.debug.print("TLS Client Integration Tests\n", .{});
    std.debug.print("============================\n", .{});
    std.debug.print("Make sure the Go test server is running:\n", .{});
    std.debug.print("  cd lib/tls/test/server && go run main.go\n\n", .{});

    var passed: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    for (test_cases) |tc| {
        runTest(tc) catch |err| {
            if (err == error.ConnectionFailed) {
                skipped += 1;
            } else {
                failed += 1;
            }
            continue;
        };
        passed += 1;
    }

    std.debug.print("\n============================\n", .{});
    std.debug.print("Results: {d} passed, {d} failed, {d} skipped\n", .{ passed, failed, skipped });

    if (failed > 0) {
        return error.TestsFailed;
    }
}
