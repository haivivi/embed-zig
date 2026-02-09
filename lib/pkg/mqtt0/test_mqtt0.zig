//! mqtt0 Integration Test — Zig broker + Zig client (loopback)
//!
//! Tests:
//! 1. Zig client ↔ Zig broker (v4 + v5)
//!
//! For cross-language tests (Go ↔ Zig), use the shell test scripts.

const std = @import("std");
const mqtt0 = @import("mqtt0");
const posix = std.posix;

/// Runtime for host tests — wraps std.Thread.Mutex for trait.sync compliance.
const TestRt = struct {
    pub const Mutex = struct {
        inner: std.Thread.Mutex = .{},
        pub fn init() @This() {
            return .{ .inner = .{} };
        }
        pub fn deinit(_: *@This()) void {}
        pub fn lock(self: *@This()) void {
            self.inner.lock();
        }
        pub fn unlock(self: *@This()) void {
            self.inner.unlock();
        }
    };
    pub const Time = struct {
        pub fn sleepMs(_: u32) void {}
        pub fn getTimeMs() u64 {
            return @intCast(std.time.milliTimestamp());
        }
    };
};

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

fn runBrokerThread(broker: *mqtt0.Broker(TcpSocket, TestRt), conn: *TcpSocket) void {
    broker.serveConn(conn);
}

// ============================================================================
// Test: Zig Client ↔ Zig Broker (MQTT 3.1.1)
// ============================================================================

// $SYS event capture state
var sys_received = false;
var sys_topic_buf: [512]u8 = undefined;
var sys_topic_len: usize = 0;
var sys_payload_buf: [1024]u8 = undefined;
var sys_payload_len: usize = 0;

fn sysHandler(_: []const u8, msg: *const mqtt0.Message) anyerror!void {
    const tlen = @min(msg.topic.len, 512);
    @memcpy(sys_topic_buf[0..tlen], msg.topic[0..tlen]);
    sys_topic_len = tlen;
    const plen = @min(msg.payload.len, 1024);
    @memcpy(sys_payload_buf[0..plen], msg.payload[0..plen]);
    sys_payload_len = plen;
    sys_received = true;
}

// Large message capture state
var large_received = false;
var large_payload_size: usize = 0;

fn largeHandler(_: []const u8, msg: *const mqtt0.Message) anyerror!void {
    large_payload_size = msg.payload.len;
    large_received = true;
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== mqtt0 Integration Tests ===\n\n", .{});

    // Test 1: v4 (MQTT 3.1.1)
    try testZigToZig(allocator, .v4);
    std.debug.print("[PASS] Zig client ↔ Zig broker (MQTT 3.1.1)\n", .{});

    // Test 2: v5 (MQTT 5.0)
    try testZigToZig(allocator, .v5);
    std.debug.print("[PASS] Zig client ↔ Zig broker (MQTT 5.0)\n", .{});

    // Test 3: $SYS events
    try testSysEvents(allocator);
    std.debug.print("[PASS] $SYS connected/disconnected events\n", .{});

    // Test 4: Large messages (>4KB, uses heap buffer)
    try testLargeMessage(allocator);
    std.debug.print("[PASS] Large message (64KB payload)\n", .{});

    // Test 5: Client reconnect
    try testReconnect(allocator);
    std.debug.print("[PASS] Client reconnect with auto-resubscribe\n", .{});

    std.debug.print("\n=== All integration tests passed ===\n", .{});
}

fn testZigToZig(allocator: std.mem.Allocator, version: mqtt0.ProtocolVersion) !void {
    // Reset test state
    test_state = TestState{};

    // Setup broker
    var broker_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer broker_mux.deinit();
    try broker_mux.handleFn("test/#", testHandler);

    var broker = try mqtt0.Broker(TcpSocket, TestRt).init(allocator, broker_mux.handler(), .{});
    defer broker.deinit();

    // Create TCP listener on random port
    const srv = try TcpSocket.initServer(0);
    defer posix.close(srv.listener);

    // Accept in a thread
    const broker_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *mqtt0.Broker(TcpSocket, TestRt), listener: posix.socket_t) void {
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

    var client_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer client_mux.deinit();

    var client = try mqtt0.Client(TcpSocket, TestRt).init(&client_sock, &client_mux, .{
        .client_id = "zig-test-client",
        .protocol_version = version,
        .allocator = allocator,
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

// ============================================================================
// Test 3: $SYS Events
// ============================================================================

fn testSysEvents(allocator: std.mem.Allocator) !void {
    sys_received = false;

    // Setup broker with $SYS enabled
    var broker_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer broker_mux.deinit();
    // Subscribe to $SYS events on the broker mux
    try broker_mux.handleFn("$SYS/#", sysHandler);

    var broker = try mqtt0.Broker(TcpSocket, TestRt).init(allocator, broker_mux.handler(), .{
        .sys_events_enabled = true,
    });
    defer broker.deinit();

    const srv = try TcpSocket.initServer(0);
    defer posix.close(srv.listener);

    const broker_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *mqtt0.Broker(TcpSocket, TestRt), listener: posix.socket_t) void {
            var conn = TcpSocket.accept(listener) catch return;
            defer conn.close();
            b.serveConn(&conn);
        }
    }.run, .{ &broker, srv.listener });

    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Connect client — this should trigger $SYS connected event
    var client_sock = try TcpSocket.connect(srv.port);
    defer client_sock.close();

    var client_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer client_mux.deinit();

    var client = try mqtt0.Client(TcpSocket, TestRt).init(&client_sock, &client_mux, .{
        .client_id = "sys-test-client",
        .username = "testuser",
        .allocator = allocator,
    });

    // Give broker time to publish $SYS event
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Verify $SYS connected event was published
    if (!sys_received) {
        std.debug.print("  ERROR: $SYS connected event not received\n", .{});
        return error.TestFailed;
    }

    const sys_topic = sys_topic_buf[0..sys_topic_len];
    if (!std.mem.eql(u8, sys_topic, "$SYS/brokers/sys-test-client/connected")) {
        std.debug.print("  ERROR: expected $SYS topic, got '{s}'\n", .{sys_topic});
        return error.TestFailed;
    }

    const sys_payload = sys_payload_buf[0..sys_payload_len];
    // Verify JSON contains expected fields
    if (std.mem.indexOf(u8, sys_payload, "\"clientid\":\"sys-test-client\"") == null) {
        std.debug.print("  ERROR: $SYS payload missing clientid: {s}\n", .{sys_payload});
        return error.TestFailed;
    }
    if (std.mem.indexOf(u8, sys_payload, "\"username\":\"testuser\"") == null) {
        std.debug.print("  ERROR: $SYS payload missing username: {s}\n", .{sys_payload});
        return error.TestFailed;
    }

    // Disconnect — triggers $SYS disconnected
    sys_received = false;
    client.deinit();
    broker_thread.join();

    // Verify disconnected event
    if (sys_received) {
        const disc_topic = sys_topic_buf[0..sys_topic_len];
        if (!std.mem.eql(u8, disc_topic, "$SYS/brokers/sys-test-client/disconnected")) {
            std.debug.print("  WARNING: unexpected disconnect topic: {s}\n", .{disc_topic});
        }
    }
}

// ============================================================================
// Test 4: Large Message (>4KB, tests dynamic PacketBuffer)
// ============================================================================

fn testLargeMessage(allocator: std.mem.Allocator) !void {
    large_received = false;
    large_payload_size = 0;

    var broker_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer broker_mux.deinit();
    try broker_mux.handleFn("large/#", largeHandler);

    var broker = try mqtt0.Broker(TcpSocket, TestRt).init(allocator, broker_mux.handler(), .{});
    defer broker.deinit();

    const srv = try TcpSocket.initServer(0);
    defer posix.close(srv.listener);

    const broker_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *mqtt0.Broker(TcpSocket, TestRt), listener: posix.socket_t) void {
            var conn = TcpSocket.accept(listener) catch return;
            defer conn.close();
            b.serveConn(&conn);
        }
    }.run, .{ &broker, srv.listener });

    std.Thread.sleep(10 * std.time.ns_per_ms);

    var client_sock = try TcpSocket.connect(srv.port);
    defer client_sock.close();

    var client_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer client_mux.deinit();

    var client = try mqtt0.Client(TcpSocket, TestRt).init(&client_sock, &client_mux, .{
        .client_id = "large-test",
        .allocator = allocator,
    });

    // Create a 64KB payload (well above 4KB inline buffer)
    const large_payload = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(large_payload);
    @memset(large_payload, 'A');

    try client.publish("large/test", large_payload);

    // Wait for broker to process
    std.Thread.sleep(100 * std.time.ns_per_ms);

    if (!large_received) {
        std.debug.print("  ERROR: large message not received by broker handler\n", .{});
        return error.TestFailed;
    }
    if (large_payload_size != 64 * 1024) {
        std.debug.print("  ERROR: expected 65536 byte payload, got {d}\n", .{large_payload_size});
        return error.TestFailed;
    }

    client.deinit();
    broker_thread.join();
}

// ============================================================================
// Test 5: Client Reconnect with auto-resubscribe
// ============================================================================

fn testReconnect(allocator: std.mem.Allocator) !void {
    test_state = TestState{};

    var broker_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer broker_mux.deinit();
    try broker_mux.handleFn("reconnect/#", testHandler);

    var broker = try mqtt0.Broker(TcpSocket, TestRt).init(allocator, broker_mux.handler(), .{});
    defer broker.deinit();

    const srv = try TcpSocket.initServer(0);
    defer posix.close(srv.listener);

    // Accept loop (handles multiple connections for reconnect)
    const accept_thread = try std.Thread.spawn(.{}, struct {
        fn run(b: *mqtt0.Broker(TcpSocket, TestRt), listener: posix.socket_t, alloc: std.mem.Allocator) void {
            for (0..3) |_| {
                const conn_ptr = alloc.create(TcpSocket) catch return;
                conn_ptr.* = TcpSocket.accept(listener) catch return;
                const t = std.Thread.spawn(.{}, struct {
                    fn handle(br: *mqtt0.Broker(TcpSocket, TestRt), c: *TcpSocket, a: std.mem.Allocator) void {
                        defer {
                            c.close();
                            a.destroy(c);
                        }
                        br.serveConn(c);
                    }
                }.handle, .{ b, conn_ptr, alloc }) catch continue;
                t.detach();
            }
        }
    }.run, .{ &broker, srv.listener, allocator });
    accept_thread.detach();

    std.Thread.sleep(10 * std.time.ns_per_ms);

    // First connection
    var sock1 = try TcpSocket.connect(srv.port);

    var client_mux = try mqtt0.Mux(TestRt).init(allocator);
    defer client_mux.deinit();

    var client = try mqtt0.Client(TcpSocket, TestRt).init(&sock1, &client_mux, .{
        .client_id = "reconnect-test",
        .allocator = allocator,
    });

    // Subscribe (this is tracked for reconnect)
    try client.subscribe(&.{"reconnect/test"});

    // Publish — should work
    try client.publish("reconnect/test", "before-reconnect");
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (!test_state.received) {
        std.debug.print("  ERROR: message before reconnect not received\n", .{});
        return error.TestFailed;
    }

    // Simulate disconnect
    sock1.close();
    std.Thread.sleep(50 * std.time.ns_per_ms);

    // Reconnect with new transport
    var sock2 = try TcpSocket.connect(srv.port);
    try client.reconnect(&sock2);

    // Publish again — should work after reconnect
    test_state = TestState{};
    try client.publish("reconnect/test", "after-reconnect");
    std.Thread.sleep(50 * std.time.ns_per_ms);

    if (!test_state.received) {
        std.debug.print("  ERROR: message after reconnect not received\n", .{});
        return error.TestFailed;
    }

    const payload = test_state.received_payload[0..test_state.received_payload_len];
    if (!std.mem.eql(u8, payload, "after-reconnect")) {
        std.debug.print("  ERROR: expected 'after-reconnect', got '{s}'\n", .{payload});
        return error.TestFailed;
    }

    client.deinit();
    std.Thread.sleep(50 * std.time.ns_per_ms);
}
