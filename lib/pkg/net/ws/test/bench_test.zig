//! WebSocket Benchmark Tests — BM1-BM5
//!
//! Performance and stress tests using MockWsServer.
//! BM1: 1000 sequential text messages
//! BM2: 500 × 1KB binary frames
//! BM3: 10 concurrent connections × 100 messages
//! BM4: 64KB binary roundtrip
//! BM5: Latency P50/P99

const std = @import("std");
const ws = @import("ws");
const frame = ws.frame;
const handshake = ws.handshake;
const posix = std.posix;

// ==========================================================================
// TCP Socket
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
// MultiConnServer — echo server supporting multiple concurrent clients
// ==========================================================================

const MultiConnServer = struct {
    listen_fd: posix.socket_t,
    port: u16,
    accept_thread: ?std.Thread = null,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),

    fn init() !MultiConnServer {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        errdefer posix.close(fd);

        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, &@as([4]u8, @bitCast(@as(i32, 1)))) catch {};

        const addr = posix.sockaddr.in{
            .port = 0,
            .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
        };
        try posix.bind(fd, @ptrCast(&addr), @sizeOf(posix.sockaddr.in));
        try posix.listen(fd, 16);

        var bound_addr: posix.sockaddr.in = undefined;
        var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
        try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);

        return .{
            .listen_fd = fd,
            .port = @byteSwap(bound_addr.port),
        };
    }

    fn start(self: *MultiConnServer) !void {
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
    }

    fn stop(self: *MultiConnServer) void {
        self.running.store(false, .release);
        posix.close(self.listen_fd);
        if (self.accept_thread) |t| t.join();
    }

    fn acceptLoop(self: *MultiConnServer) void {
        while (self.running.load(.acquire)) {
            const client_fd = posix.accept(self.listen_fd, null, null, 0) catch return;
            _ = std.Thread.spawn(.{}, handleClient, .{client_fd}) catch {
                posix.close(client_fd);
                continue;
            };
        }
    }

    fn handleClient(fd: posix.socket_t) void {
        defer posix.close(fd);
        echoSession(fd) catch {};
    }
};

fn echoSession(fd: posix.socket_t) !void {
    var buf: [8192]u8 = undefined;
    var total: usize = 0;

    // Read HTTP upgrade
    while (total < buf.len) {
        const n = posix.recv(fd, buf[total..], 0) catch return;
        if (n == 0) return;
        total += n;
        if (findCRLFCRLF(buf[0..total])) |_| break;
    }

    const key = extractKey(buf[0..total]) orelse return;
    var accept: [28]u8 = undefined;
    handshake.computeAcceptKey(key, &accept);

    var resp_buf: [512]u8 = undefined;
    const resp = buildResponse(&resp_buf, &accept);
    _ = posix.send(fd, resp, 0) catch return;

    // Echo loop
    var read_buf: [131072]u8 = undefined; // 128KB for large frames
    var read_len: usize = 0;

    while (true) {
        const n = posix.recv(fd, read_buf[read_len..], 0) catch return;
        if (n == 0) return;
        read_len += n;

        while (read_len >= 2) {
            const header = frame.decodeHeader(read_buf[0..read_len]) catch break;
            const total_frame = header.header_size + @as(usize, @intCast(header.payload_len));
            if (read_len < total_frame) break;

            const payload = read_buf[header.header_size..total_frame];
            if (header.masked) {
                frame.applyMask(@constCast(payload), header.mask_key);
            }

            if (header.opcode == .close) {
                var close_buf: [frame.MAX_HEADER_SIZE + 2]u8 = undefined;
                const hdr_len = frame.encodeHeader(&close_buf, .close, payload.len, true, null);
                if (payload.len > 0) @memcpy(close_buf[hdr_len..][0..payload.len], payload);
                _ = posix.send(fd, close_buf[0 .. hdr_len + payload.len], 0) catch {};
                return;
            } else if (header.opcode == .ping) {
                var pong_buf: [frame.MAX_HEADER_SIZE + 125]u8 = undefined;
                const hdr_len = frame.encodeHeader(&pong_buf, .pong, payload.len, true, null);
                if (payload.len > 0) @memcpy(pong_buf[hdr_len..][0..payload.len], payload);
                _ = posix.send(fd, pong_buf[0 .. hdr_len + payload.len], 0) catch {};
            } else {
                var echo_hdr: [frame.MAX_HEADER_SIZE]u8 = undefined;
                const hdr_len = frame.encodeHeader(&echo_hdr, header.opcode, payload.len, true, null);
                _ = posix.send(fd, echo_hdr[0..hdr_len], 0) catch return;
                if (payload.len > 0) {
                    _ = posix.send(fd, payload, 0) catch return;
                }
            }

            const remaining = read_len - total_frame;
            if (remaining > 0) {
                ws.client.copyForward(&read_buf, read_buf[total_frame..read_len]);
            }
            read_len = remaining;
        }
    }
}

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
    if (request.len < needle.len) return null;
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

fn formatNum(buf: []u8, prefix: []const u8, n: usize) []const u8 {
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
    for (0..tmp_len) |i| {
        buf[pos + i] = tmp[tmp_len - 1 - i];
    }
    return buf[0 .. pos + tmp_len];
}

// ==========================================================================
// BM1: 1000 sequential text messages
// ==========================================================================

test "BM1: 1000 text messages sequential" {
    const allocator = std.testing.allocator;

    var server = try MultiConnServer.init();
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

    var timer = std.time.Timer.start() catch unreachable;

    var msg_buf: [32]u8 = undefined;
    for (0..1000) |i| {
        const msg_text = formatNum(&msg_buf, "msg-", i);
        try client.sendText(msg_text);
        const msg = (try client.recv()) orelse return error.UnexpectedNull;
        try std.testing.expectEqualSlices(u8, msg_text, msg.payload);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    const msg_per_s = if (elapsed_ms > 0) 1000 * 1000 / elapsed_ms else 0;
    std.debug.print("\n[bench] WS text: 1000 msg in {}ms, {} msg/s\n", .{ elapsed_ms, msg_per_s });

    client.close();
}

// ==========================================================================
// BM2: 500 × 1KB binary frames
// ==========================================================================

test "BM2: 500x1KB binary frames" {
    const allocator = std.testing.allocator;

    var server = try MultiConnServer.init();
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

    var data: [1024]u8 = undefined;
    for (&data, 0..) |*b, i| b.* = @intCast(i % 256);

    var timer = std.time.Timer.start() catch unreachable;

    for (0..500) |_| {
        try client.sendBinary(&data);
        const msg = (try client.recv()) orelse return error.UnexpectedNull;
        try std.testing.expectEqual(ws.MessageType.binary, msg.type);
        try std.testing.expectEqual(@as(usize, 1024), msg.payload.len);
        try std.testing.expectEqualSlices(u8, &data, msg.payload);
    }

    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    const total_kb = 500;
    const mb_per_s = if (elapsed_ms > 0) total_kb * 1000 / elapsed_ms else 0;
    std.debug.print("\n[bench] WS binary: 500x1KB in {}ms, {} KB/s\n", .{ elapsed_ms, mb_per_s });

    client.close();
}

// ==========================================================================
// BM3: 10 concurrent connections × 100 messages
// ==========================================================================

test "BM3: 10 concurrent connections x100 messages" {
    const allocator = std.testing.allocator;

    var server = try MultiConnServer.init();
    try server.start();
    defer server.stop();

    const N_CLIENTS = 10;
    const N_MSGS = 100;

    var pass_count = std.atomic.Value(u32).init(0);

    var timer = std.time.Timer.start() catch unreachable;

    var threads: [N_CLIENTS]std.Thread = undefined;
    for (0..N_CLIENTS) |i| {
        const ctx = ClientCtx{
            .allocator = allocator,
            .port = server.port,
            .client_id = i,
            .n_msgs = N_MSGS,
            .pass_count = &pass_count,
        };
        threads[i] = try std.Thread.spawn(.{}, clientWorker, .{ctx});
    }
    for (&threads) |t| t.join();

    const elapsed_ns = timer.read();
    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
    const total = N_CLIENTS * N_MSGS;
    std.debug.print("\n[bench] WS 10-concurrent: {}x{} msg in {}ms\n", .{ N_CLIENTS, N_MSGS, elapsed_ms });

    try std.testing.expectEqual(@as(u32, N_CLIENTS), pass_count.load(.acquire));
    _ = total;
}

const ClientCtx = struct {
    allocator: std.mem.Allocator,
    port: u16,
    client_id: usize,
    n_msgs: usize,
    pass_count: *std.atomic.Value(u32),
};

fn clientWorker(ctx: ClientCtx) void {
    var sock = TcpSocket.connect(.{ 127, 0, 0, 1 }, ctx.port) catch return;
    defer sock.close();

    var client = ws.Client(TcpSocket).init(ctx.allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
    }) catch return;
    defer client.deinit();

    var msg_buf: [64]u8 = undefined;
    var ok: bool = true;
    for (0..ctx.n_msgs) |i| {
        const prefix_end = formatNum(msg_buf[0..32], "c", ctx.client_id);
        msg_buf[prefix_end.len] = '-';
        const full = formatNum(msg_buf[0..64], msg_buf[0 .. prefix_end.len + 1], i);

        client.sendText(full) catch {
            ok = false;
            break;
        };
        const msg = (client.recv() catch null) orelse {
            ok = false;
            break;
        };
        if (!std.mem.eql(u8, full, msg.payload)) {
            ok = false;
            break;
        }
    }

    client.close();
    if (ok) _ = ctx.pass_count.fetchAdd(1, .acq_rel);
}

// ==========================================================================
// BM4: 64KB binary roundtrip
// ==========================================================================

test "BM4: 64KB binary roundtrip" {
    const allocator = std.testing.allocator;

    var server = try MultiConnServer.init();
    try server.start();
    defer server.stop();

    var sock = try TcpSocket.connect(.{ 127, 0, 0, 1 }, server.port);
    defer sock.close();

    var client = try ws.Client(TcpSocket).init(allocator, &sock, .{
        .host = "localhost",
        .path = "/",
        .rng_fill = rngFill,
        .buffer_size = 65536 + 1024, // 64KB payload + header room
    });
    defer client.deinit();

    const data = try allocator.alloc(u8, 65536);
    defer allocator.free(data);
    for (data, 0..) |*b, i| b.* = @intCast(i % 256);

    var timer = std.time.Timer.start() catch unreachable;

    try client.sendBinary(data);
    const msg = (try client.recv()) orelse return error.UnexpectedNull;
    try std.testing.expectEqual(ws.MessageType.binary, msg.type);
    try std.testing.expectEqual(@as(usize, 65536), msg.payload.len);
    try std.testing.expectEqualSlices(u8, data, msg.payload);

    const elapsed_ns = timer.read();
    const elapsed_us = elapsed_ns / std.time.ns_per_us;
    std.debug.print("\n[bench] WS large-frame: 64KB roundtrip in {}us\n", .{elapsed_us});

    client.close();
}

// ==========================================================================
// BM5: Latency P50/P99
// ==========================================================================

test "BM5: latency P50/P99" {
    const allocator = std.testing.allocator;

    var server = try MultiConnServer.init();
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

    const N = 100;
    var latencies: [N]u64 = undefined;

    for (0..N) |i| {
        var t0 = std.time.Timer.start() catch unreachable;
        try client.sendText("ping");
        _ = (try client.recv()) orelse return error.UnexpectedNull;
        latencies[i] = t0.read();
    }

    // Sort for percentiles
    std.mem.sort(u64, &latencies, {}, std.sort.asc(u64));

    const p50 = latencies[N / 2] / std.time.ns_per_us;
    const p99 = latencies[N * 99 / 100] / std.time.ns_per_us;
    std.debug.print("\n[bench] WS latency: P50={}us, P99={}us\n", .{ p50, p99 });

    client.close();
}
