//! WebSocket e2e tests — Client ↔ MockWsServer
//!
//! Tests E1-E6: text echo, binary echo, ping/pong, 50 messages,
//! server-initiated close, extra headers.
//!
//! The MockWsServer is a minimal TCP server that performs the WebSocket
//! handshake and echoes all received frames back to the client.

const std = @import("std");
const ws = @import("ws");
const frame = ws.frame;
const handshake = ws.handshake;
const posix = std.posix;

// ==========================================================================
// TCP Socket wrapper (for the client side)
// ==========================================================================

const TcpSocket = struct {
    fd: posix.socket_t,

    pub fn connect(addr: [4]u8, port: u16) !TcpSocket {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        const sa = posix.sockaddr.in{
            .port = @byteSwap(port),
            .addr = @bitCast(addr),
        };
        try posix.connect(fd, @ptrCast(&sa), @sizeOf(posix.sockaddr.in));
        return .{ .fd = fd };
    }

    pub fn send(self: *TcpSocket, data: []const u8) !usize {
        return posix.send(self.fd, data, 0) catch return error.SendFailed;
    }

    pub fn recv(self: *TcpSocket, buf: []u8) !usize {
        const n = posix.recv(self.fd, buf, 0) catch return error.RecvFailed;
        if (n == 0) return error.Closed;
        return n;
    }

    pub fn close(self: *TcpSocket) void {
        posix.close(self.fd);
    }
};

fn rngFill(buf: []u8) void {
    std.crypto.random.bytes(buf);
}

// ==========================================================================
// MockWsServer — minimal WebSocket echo server
// ==========================================================================

const MockWsServer = struct {
    listen_fd: posix.socket_t,
    port: u16,
    server_thread: ?std.Thread = null,
    /// Headers captured from the last handshake request
    captured_headers: [2048]u8 = undefined,
    captured_headers_len: usize = 0,

    fn start(self: *MockWsServer) !void {
        self.server_thread = try std.Thread.spawn(.{}, serverLoop, .{self});
    }

    fn stop(self: *MockWsServer) void {
        posix.close(self.listen_fd);
        if (self.server_thread) |t| t.join();
    }

    fn init() !MockWsServer {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        // Allow port reuse
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &@as([4]u8, @bitCast(@as(i32, 1)))) catch {};

        const addr = posix.sockaddr.in{
            .port = 0, // kernel assigns port
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 1);

        // Get assigned port
        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);

        return .{
            .listen_fd = fd,
            .port = @byteSwap(bound_addr.port),
        };
    }

    fn serverLoop(self: *MockWsServer) void {
        const client_fd = posix.accept(self.listen_fd, null, null, 0) catch return;
        defer posix.close(client_fd);

        serverHandleClient(self, client_fd) catch |err| {
            std.debug.print("[MockWsServer] error: {}\n", .{err});
        };
    }

    fn serverHandleClient(self: *MockWsServer, fd: posix.socket_t) !void {
        var buf: [4096]u8 = undefined;
        var total: usize = 0;

        // Read HTTP upgrade request
        while (total < buf.len) {
            const n = posix.recv(fd, buf[total..], 0) catch return;
            if (n == 0) return;
            total += n;

            if (findCRLFCRLF(buf[0..total])) |_| break;
        }

        // Capture headers for E6 test
        const cap_len = @min(total, self.captured_headers.len);
        @memcpy(self.captured_headers[0..cap_len], buf[0..cap_len]);
        self.captured_headers_len = cap_len;

        // Extract Sec-WebSocket-Key
        const key = extractKey(buf[0..total]) orelse return;

        // Compute accept
        var accept: [28]u8 = undefined;
        handshake.computeAcceptKey(key, &accept);

        // Send 101 response
        var resp_buf: [512]u8 = undefined;
        const resp = buildResponse(&resp_buf, &accept);
        _ = posix.send(fd, resp, 0) catch return;

        // Echo loop: read frames, unmask, re-send (unmasked, as server)
        var read_buf: [8192]u8 = undefined;
        var read_len: usize = 0;

        while (true) {
            // Read more data
            const n = posix.recv(fd, read_buf[read_len..], 0) catch return;
            if (n == 0) return;
            read_len += n;

            // Process all complete frames
            while (read_len >= 2) {
                const header = frame.decodeHeader(read_buf[0..read_len]) catch break;
                const total_frame = header.header_size + @as(usize, @intCast(header.payload_len));
                if (read_len < total_frame) break;

                const payload_start = header.header_size;
                const payload_end = total_frame;
                const payload = read_buf[payload_start..payload_end];

                if (header.masked) {
                    frame.applyMask(payload, header.mask_key);
                }

                // Handle close
                if (header.opcode == .close) {
                    var close_frame: [frame.MAX_HEADER_SIZE + 2]u8 = undefined;
                    const hdr_len = frame.encodeHeader(&close_frame, .close, payload.len, true, null);
                    if (payload.len > 0) {
                        @memcpy(close_frame[hdr_len..][0..payload.len], payload);
                    }
                    _ = posix.send(fd, close_frame[0 .. hdr_len + payload.len], 0) catch {};
                    return;
                }

                // Handle ping: reply with pong
                if (header.opcode == .ping) {
                    var pong_frame: [frame.MAX_HEADER_SIZE + 125]u8 = undefined;
                    const hdr_len = frame.encodeHeader(&pong_frame, .pong, payload.len, true, null);
                    if (payload.len > 0) {
                        @memcpy(pong_frame[hdr_len..][0..payload.len], payload);
                    }
                    _ = posix.send(fd, pong_frame[0 .. hdr_len + payload.len], 0) catch {};
                } else {
                    // Echo: send back same opcode + payload (unmasked, server→client)
                    var echo_hdr: [frame.MAX_HEADER_SIZE]u8 = undefined;
                    const hdr_len = frame.encodeHeader(&echo_hdr, header.opcode, payload.len, true, null);
                    _ = posix.send(fd, echo_hdr[0..hdr_len], 0) catch return;
                    if (payload.len > 0) {
                        _ = posix.send(fd, payload, 0) catch return;
                    }
                }

                // Shift remaining data
                const remaining = read_len - total_frame;
                if (remaining > 0) {
                    ws.client.copyForward(&read_buf, read_buf[total_frame..read_len]);
                }
                read_len = remaining;
            }
        }
    }

    fn sendServerPing(self: *MockWsServer, fd: posix.socket_t) void {
        _ = self;
        var ping_buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
        const hdr_len = frame.encodeHeader(&ping_buf, .ping, 0, true, null);
        _ = posix.send(fd, ping_buf[0..hdr_len], 0) catch {};
    }
};

fn findCRLFCRLF(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n')
            return i;
    }
    return null;
}

fn extractKey(request: []const u8) ?[]const u8 {
    const needle = "Sec-WebSocket-Key: ";
    for (0..request.len - needle.len) |i| {
        if (std.mem.eql(u8, request[i..][0..needle.len], needle)) {
            const start = i + needle.len;
            var end = start;
            while (end < request.len and request[end] != '\r') : (end += 1) {}
            return request[start..end];
        }
    }
    return null;
}

fn buildResponse(buf: []u8, accept: []const u8) []const u8 {
    const parts = [_][]const u8{
        "HTTP/1.1 101 Switching Protocols\r\n",
        "Upgrade: websocket\r\n",
        "Connection: Upgrade\r\n",
        "Sec-WebSocket-Accept: ",
        accept,
        "\r\n\r\n",
    };
    var pos: usize = 0;
    for (parts) |part| {
        @memcpy(buf[pos..][0..part.len], part);
        pos += part.len;
    }
    return buf[0..pos];
}

fn containsStr(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.mem.eql(u8, haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

// ==========================================================================
// E1: Text echo roundtrip
// ==========================================================================

test "E1: text echo roundtrip" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    // Send and receive "hello"
    try client.sendText("hello");
    const msg1 = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws.MessageType.text, msg1.type);
    try std.testing.expectEqualSlices(u8, "hello", msg1.payload);

    // Send and receive "world"
    try client.sendText("world");
    const msg2 = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws.MessageType.text, msg2.type);
    try std.testing.expectEqualSlices(u8, "world", msg2.payload);

    // Graceful close
    client.close();
}

// ==========================================================================
// E2: Binary echo
// ==========================================================================

test "E2: binary echo" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    // 256 bytes of patterned data
    var data: [256]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    try client.sendBinary(&data);
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws.MessageType.binary, msg.type);
    try std.testing.expectEqualSlices(u8, &data, msg.payload);

    client.close();
}

// ==========================================================================
// E3: Ping/pong auto handling
// ==========================================================================

test "E3: ping pong" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    // Client sends ping, server echoes as pong
    try client.sendPing();
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws.MessageType.pong, msg.type);

    client.close();
}

// ==========================================================================
// E4: 50 consecutive messages
// ==========================================================================

test "E4: 50 consecutive messages" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    var buf: [32]u8 = undefined;
    for (0..50) |i| {
        const msg_text = formatNum(&buf, i);
        try client.sendText(msg_text);
        const msg = (try client.recv()) orelse return error.UnexpectedNull;
        try std.testing.expectEqual(ws.MessageType.text, msg.type);
        try std.testing.expectEqualSlices(u8, msg_text, msg.payload);
    }

    client.close();
}

fn formatNum(buf: []u8, n: usize) []const u8 {
    const prefix = "msg-";
    @memcpy(buf[0..prefix.len], prefix);
    const pos: usize = prefix.len;

    if (n == 0) {
        buf[pos] = '0';
        return buf[0 .. pos + 1];
    }

    var tmp: [20]u8 = undefined;
    var tmp_len: usize = 0;
    var val = n;
    while (val > 0) {
        tmp[tmp_len] = @intCast(val % 10 + '0');
        tmp_len += 1;
        val /= 10;
    }
    // Reverse
    for (0..tmp_len) |i| {
        buf[pos + i] = tmp[tmp_len - 1 - i];
    }
    return buf[0 .. pos + tmp_len];
}

// ==========================================================================
// E5: Server-initiated close
// ==========================================================================

test "E5: server-initiated close" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    });
    defer client.deinit();

    // Client sends close, server echoes close
    try client.sendClose(1000);

    // recv should return null (connection closed)
    const result = try client.recv();
    try std.testing.expectEqual(@as(?ws.Message, null), result);
}

// ==========================================================================
// E6: Extra headers (Doubao compatibility)
// ==========================================================================

test "E6: extra headers" {
    const allocator = std.testing.allocator;

    var server = try MockWsServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    const headers = [_][2][]const u8{
        .{ "X-Api-App-Key", "test-key-12345" },
        .{ "X-Api-Access-Key", "access-token-abc" },
        .{ "X-Api-Resource-Id", "volc.speech.dialog" },
    };

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/api/v3/realtime",
        .extra_headers = &headers,
        .rng_fill = rngFill,
    });
    defer client.deinit();

    // Give server thread time to capture headers
    std.Thread.sleep(10 * std.time.ns_per_ms);

    // Verify server captured our custom headers
    const captured = server.captured_headers[0..server.captured_headers_len];
    try std.testing.expect(containsStr(captured, "X-Api-App-Key: test-key-12345"));
    try std.testing.expect(containsStr(captured, "X-Api-Access-Key: access-token-abc"));
    try std.testing.expect(containsStr(captured, "X-Api-Resource-Id: volc.speech.dialog"));
    try std.testing.expect(containsStr(captured, "GET /api/v3/realtime HTTP/1.1"));

    // Send a message to verify the connection works
    try client.sendText("doubao-test");
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws.MessageType.text, msg.type);
    try std.testing.expectEqualSlices(u8, "doubao-test", msg.payload);

    client.close();
}
