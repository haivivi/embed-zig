//! mqtt0 Integration Test — Zig broker + Zig client (loopback)
//!
//! Tests:
//! 1. Zig client ↔ Zig broker (v4 + v5)
//!
//! For cross-language tests (Go ↔ Zig), use the shell test scripts.

const std = @import("std");
const mqtt0 = @import("mqtt0");
const posix = std.posix;

/// Simple TCP socket wrapper matching the Transport interface (send/recv)
const TcpSocket = struct {
    fd: posix.socket_t,

    fn initServer(port: u16) !struct { listener: posix.socket_t, port: u16 } {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // SO_REUSEADDR
        const enable: u32 = 1;
        try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = 0, // INADDR_ANY
        };
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        try posix.listen(fd, 5);

        // Get actual port (for port 0)
        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
        const actual_port = std.mem.bigToNative(u16, bound_addr.port);

        return .{ .listener = fd, .port = actual_port };
    }

    fn accept(listener: posix.socket_t) !TcpSocket {
        const fd = try posix.accept(listener, null, null, 0);
        return .{ .fd = fd };
    }

    fn connect(port: u16) !TcpSocket {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
        };
        try posix.connect(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        return .{ .fd = fd };
    }

    // Transport interface
    pub fn send(self: *TcpSocket, data: []const u8) !usize {
        return posix.send(self.fd, data, 0) catch |err| switch (err) {
            error.BrokenPipe, error.ConnectionResetByPeer => return error.ConnectionClosed,
            else => return error.SendFailed,
        };
    }

    pub fn recv(self: *TcpSocket, buf: []u8) !usize {
        const n = posix.recv(self.fd, buf, 0) catch |err| switch (err) {
            error.ConnectionResetByPeer => return error.ConnectionClosed,
            else => return error.RecvFailed,
        };
        if (n == 0) return error.ConnectionClosed;
        return n;
    }

    fn close(self: *TcpSocket) void {
        posix.close(self.fd);
    }
};

const TestState = struct {
    received_topic: [256]u8 = undefined,
    received_topic_len: usize = 0,
    received_payload: [256]u8 = undefined,
    received_payload_len: usize = 0,
    received: bool = false,
};

var test_state = TestState{};

fn testHandler(_: []const u8, msg: *const mqtt0.Message) anyerror!void {
    const tlen = @min(msg.topic.len, 256);
    @memcpy(test_state.received_topic[0..tlen], msg.topic[0..tlen]);
    test_state.received_topic_len = tlen;
    const plen = @min(msg.payload.len, 256);
    @memcpy(test_state.received_payload[0..plen], msg.payload[0..plen]);
    test_state.received_payload_len = plen;
    test_state.received = true;
}

fn runBrokerThread(broker: *mqtt0.Broker(TcpSocket), conn: *TcpSocket) void {
    broker.serveConn(conn);
}

// ============================================================================
// Test: Zig Client ↔ Zig Broker (MQTT 3.1.1)
// ============================================================================

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== mqtt0 Integration Tests ===\n\n", .{});

    // Test 1: v4 (MQTT 3.1.1)
    try testZigToZig(allocator, .v4);
    std.debug.print("[PASS] Zig client ↔ Zig broker (MQTT 3.1.1)\n", .{});

    // Test 2: v5 (MQTT 5.0)
    try testZigToZig(allocator, .v5);
    std.debug.print("[PASS] Zig client ↔ Zig broker (MQTT 5.0)\n", .{});

    std.debug.print("\n=== All integration tests passed ===\n", .{});
}

fn testZigToZig(allocator: std.mem.Allocator, version: mqtt0.ProtocolVersion) !void {
    // Reset test state
    test_state = TestState{};

    // Setup broker
    var broker_mux = try mqtt0.Mux.init(allocator);
    defer broker_mux.deinit();
    try broker_mux.handleFn("test/#", testHandler);

    var broker = try mqtt0.Broker(TcpSocket).init(allocator, broker_mux.handler(), .{});
    defer broker.deinit();

    // Create TCP listener on random port
    const srv = try TcpSocket.initServer(0);
    defer posix.close(srv.listener);

    // Accept in a thread
    const broker_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *mqtt0.Broker(TcpSocket), listener: posix.socket_t) void {
            var conn = TcpSocket.accept(listener) catch return;
            defer conn.close();
            b.serveConn(&conn);
        }
    }.run, .{ &broker, srv.listener });

    // Give broker thread time to start
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Connect client
    var client_sock = try TcpSocket.connect(srv.port);
    defer client_sock.close();

    var client_mux = try mqtt0.Mux.init(allocator);
    defer client_mux.deinit();

    var client = try mqtt0.Client(TcpSocket).init(&client_sock, &client_mux, .{
        .client_id = "zig-test-client",
        .protocol_version = version,
    });

    // Subscribe
    try client.subscribe(&.{"test/hello"});

    // Publish
    try client.publish("test/hello", "world");

    // Give broker time to process
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify broker handler received the message
    if (!test_state.received) {
        std.debug.print("  ERROR: broker handler did not receive message\n", .{});
        return error.TestFailed;
    }

    const topic = test_state.received_topic[0..test_state.received_topic_len];
    const payload = test_state.received_payload[0..test_state.received_payload_len];

    if (!std.mem.eql(u8, topic, "test/hello")) {
        std.debug.print("  ERROR: expected topic 'test/hello', got '{s}'\n", .{topic});
        return error.TestFailed;
    }
    if (!std.mem.eql(u8, payload, "world")) {
        std.debug.print("  ERROR: expected payload 'world', got '{s}'\n", .{payload});
        return error.TestFailed;
    }

    // Disconnect
    client.deinit();
    broker_thread.join();
}
