const std = @import("std");
const posix = std.posix;
const http = @import("http");
const print = std.debug.print;
const testing = std.testing;

// ============================================================================
// TcpSocket
// ============================================================================

const TcpSocket = struct {
    fd: posix.socket_t,

    pub fn tcp() !TcpSocket {
        const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
        return .{ .fd = fd };
    }

    pub fn send(self: *TcpSocket, data: []const u8) !usize {
        return posix.send(self.fd, data, 0) catch return error.SendFailed;
    }

    pub fn recv(self: *TcpSocket, buf: []u8) !usize {
        const n = posix.recv(self.fd, buf, 0) catch |err| {
            return if (err == error.WouldBlock) error.Timeout else error.RecvFailed;
        };
        if (n == 0) return error.Closed;
        return n;
    }

    pub const Error = error{ SendFailed, RecvFailed, Closed, Timeout };

    pub fn close(self: *TcpSocket) void {
        posix.close(self.fd);
    }

    fn connectTo(port: u16) !TcpSocket {
        var sock = try TcpSocket.tcp();
        errdefer sock.close();
        const addr = posix.sockaddr.in{
            .family = posix.AF.INET,
            .port = std.mem.nativeToBig(u16, port),
            .addr = std.mem.nativeToBig(u32, 0x7f000001),
        };
        try posix.connect(sock.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        return sock;
    }
};

// ============================================================================
// BufferedReader — tracks unconsumed data across keep-alive responses
// ============================================================================

fn BufferedReader(comptime buf_size: usize) type {
    return struct {
        sock: *TcpSocket,
        buf: [buf_size]u8 = undefined,
        len: usize = 0,

        const Self = @This();

        fn init(sock: *TcpSocket) Self {
            return .{ .sock = sock };
        }

        fn readOneResponse(self: *Self) !bool {
            while (true) {
                if (self.findCompleteResponse()) |resp_end| {
                    const is_200 = std.mem.startsWith(u8, self.buf[0..self.len], "HTTP/1.1 200");
                    // Shift unconsumed data to front
                    if (resp_end < self.len) {
                        std.mem.copyForwards(u8, self.buf[0 .. self.len - resp_end], self.buf[resp_end..self.len]);
                        self.len -= resp_end;
                    } else {
                        self.len = 0;
                    }
                    return is_200;
                }

                if (self.len >= self.buf.len) return error.BufferFull;

                const n = posix.recv(self.sock.fd, self.buf[self.len..], 0) catch return error.RecvError;
                if (n == 0) return error.ConnectionClosed;
                self.len += n;
            }
        }

        fn findCompleteResponse(self: *Self) ?usize {
            const data = self.buf[0..self.len];
            const hdr_end = std.mem.indexOf(u8, data, "\r\n\r\n") orelse return null;
            const body_start = hdr_end + 4;

            if (std.mem.indexOf(u8, data[0..hdr_end], "Content-Length: ")) |cl_start| {
                const val_start = cl_start + "Content-Length: ".len;
                const val_end = std.mem.indexOfPos(u8, data[0..hdr_end], val_start, "\r\n") orelse hdr_end;
                const content_len = std.fmt.parseUnsigned(usize, data[val_start..val_end], 10) catch 0;
                const total = body_start + content_len;
                return if (self.len >= total) total else null;
            }
            return body_start;
        }

        const ReadError = error{ BufferFull, RecvError, ConnectionClosed };
    };
}

// ============================================================================
// Server configs
// ============================================================================

const SmallServer = http.Server(TcpSocket, .{
    .read_buf_size = 8192,
    .write_buf_size = 4096,
    .max_requests_per_conn = 1100,
});

const LargeServer = http.Server(TcpSocket, .{
    .read_buf_size = 20480,
    .write_buf_size = 4096,
    .max_requests_per_conn = 200,
});

// ============================================================================
// Helpers
// ============================================================================

fn startListener() !struct { fd: posix.socket_t, port: u16 } {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    const enable: u32 = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0,
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(fd, 256);

    var bound_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);

    return .{ .fd = fd, .port = std.mem.bigToNative(u16, bound_addr.port) };
}

fn acceptOne(listener_fd: posix.socket_t) !TcpSocket {
    const client_fd = try posix.accept(listener_fd, null, null, 0);
    return TcpSocket{ .fd = client_fd };
}

fn sendRaw(sock: *TcpSocket, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        sent += try posix.send(sock.fd, data[sent..], 0);
    }
}

fn recvOneResponse(sock: *TcpSocket, buf: []u8) !usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.recv(sock.fd, buf[total..], 0) catch break;
        if (n == 0) break;
        total += n;

        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |hdr_end| {
            if (std.mem.indexOf(u8, buf[0..hdr_end], "Content-Length: ")) |cl_start| {
                const val_start = cl_start + "Content-Length: ".len;
                const val_end = std.mem.indexOfPos(u8, buf[0..hdr_end], val_start, "\r\n") orelse hdr_end;
                const content_len = std.fmt.parseUnsigned(usize, buf[val_start..val_end], 10) catch 0;
                if (total >= hdr_end + 4 + content_len) break;
            } else {
                break;
            }
        }
    }
    return total;
}

fn nowMs() u64 {
    return @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_ms));
}

// ============================================================================
// Route handlers
// ============================================================================

fn handleStatus(_: *http.Request, resp: *http.Response) void {
    resp.json("{\"status\":\"ok\"}");
}

fn handleEcho(req: *http.Request, resp: *http.Response) void {
    if (req.body) |body| {
        _ = resp.contentType("application/octet-stream");
        resp.send(body);
    } else {
        resp.sendStatus(400);
    }
}

const small_routes = [_]http.Route{
    http.get("/api/status", handleStatus),
};

const large_routes = [_]http.Route{
    http.get("/api/status", handleStatus),
    http.post("/api/echo", handleEcho),
};

fn serveSmallConn(server: *const SmallServer, listener_fd: posix.socket_t) void {
    const conn = acceptOne(listener_fd) catch return;
    server.serveConn(conn);
}

fn serveLargeConn(server: *const LargeServer, listener_fd: posix.socket_t) void {
    const conn = acceptOne(listener_fd) catch return;
    server.serveConn(conn);
}

// ============================================================================
// BM1: Sequential throughput — 1000 requests keep-alive
// ============================================================================

const GET_REQUEST = "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
const CLOSE_REQUEST = "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";

test "BM1: 1000 sequential keep-alive requests" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = SmallServer.init(testing.allocator, &small_routes);
    const t = try std.Thread.spawn(.{}, serveSmallConn, .{ &server, listener.fd });
    defer t.join();

    var sock = try TcpSocket.connectTo(listener.port);
    defer sock.close();

    var reader = BufferedReader(8192).init(&sock);
    const N: usize = 1000;
    var ok_count: usize = 0;
    const start = nowMs();

    for (0..N) |_| {
        try sendRaw(&sock, GET_REQUEST);
        if (reader.readOneResponse() catch false) ok_count += 1;
    }

    const elapsed = nowMs() - start;
    const rps = if (elapsed > 0) N * 1000 / elapsed else 0;
    print("\n[bench] HTTP sequential: {d} req in {d}ms, {d} req/s\n", .{ N, elapsed, rps });
    try testing.expectEqual(N, ok_count);
}

// ============================================================================
// BM2: 100 concurrent connections
// ============================================================================

test "BM2: 100 concurrent connections" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = SmallServer.init(testing.allocator, &small_routes);
    const N = 100;

    var server_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveSmallConn, .{ &server, listener.fd });
    }

    var success = std.atomic.Value(u32).init(0);
    var client_threads: [N]std.Thread = undefined;
    const start = nowMs();

    for (0..N) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(port: u16, ok: *std.atomic.Value(u32)) void {
                var sock = TcpSocket.connectTo(port) catch return;
                defer sock.close();
                sendRaw(&sock, CLOSE_REQUEST) catch return;
                var buf: [4096]u8 = undefined;
                const len = recvOneResponse(&sock, &buf) catch return;
                if (std.mem.startsWith(u8, buf[0..len], "HTTP/1.1 200")) {
                    _ = ok.fetchAdd(1, .monotonic);
                }
            }
        }.run, .{ listener.port, &success });
    }

    for (&client_threads) |*ct| ct.join();
    for (&server_threads) |*st| st.join();

    const elapsed = nowMs() - start;
    const ok = success.load(.monotonic);
    print("\n[bench] HTTP 100-concurrent: {d}/100 success, {d}ms\n", .{ ok, elapsed });
    try testing.expectEqual(@as(u32, N), ok);
}

// ============================================================================
// BM3: Keep-alive throughput — single connection 1000 requests
// ============================================================================

test "BM3: keep-alive 1000 requests single connection" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = SmallServer.init(testing.allocator, &small_routes);
    const t = try std.Thread.spawn(.{}, serveSmallConn, .{ &server, listener.fd });
    defer t.join();

    var sock = try TcpSocket.connectTo(listener.port);
    defer sock.close();

    var reader = BufferedReader(8192).init(&sock);
    const N: usize = 1000;
    var ok_count: usize = 0;
    const start = nowMs();

    for (0..N) |_| {
        try sendRaw(&sock, GET_REQUEST);
        if (reader.readOneResponse() catch false) ok_count += 1;
    }

    const elapsed = nowMs() - start;
    const rps = if (elapsed > 0) N * 1000 / elapsed else 0;
    print("\n[bench] HTTP keep-alive: {d} req in {d}ms, {d} req/s\n", .{ N, elapsed, rps });
    try testing.expectEqual(N, ok_count);
}

// ============================================================================
// BM4: Large body throughput — 16KB POST × 100
// ============================================================================

test "BM4: 16KB POST x100 echo" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = LargeServer.init(testing.allocator, &large_routes);
    const t = try std.Thread.spawn(.{}, serveLargeConn, .{ &server, listener.fd });
    defer t.join();

    var sock = try TcpSocket.connectTo(listener.port);
    defer sock.close();

    var body: [16384]u8 = undefined;
    @memset(&body, 'X');

    var header_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "POST /api/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\n\r\n", .{body.len}) catch unreachable;

    var reader = BufferedReader(65536).init(&sock);
    const N: usize = 100;
    var ok_count: usize = 0;
    var total_bytes: usize = 0;
    const start = nowMs();

    for (0..N) |_| {
        try sendRaw(&sock, header);
        try sendRaw(&sock, &body);
        if (reader.readOneResponse() catch false) {
            ok_count += 1;
            total_bytes += body.len;
        }
    }

    const elapsed = nowMs() - start;
    const mb_per_s = if (elapsed > 0) total_bytes * 1000 / elapsed / (1024 * 1024) else 0;
    print("\n[bench] HTTP large-body: {d}x16KB in {d}ms, {d} MB/s\n", .{ N, elapsed, mb_per_s });
    try testing.expectEqual(N, ok_count);
}

// ============================================================================
// BM5: Concurrent keep-alive — 10 connections × 100 requests
// ============================================================================

test "BM5: 10 concurrent connections x 100 keep-alive requests" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = SmallServer.init(testing.allocator, &small_routes);
    const CONNS = 10;
    const REQS_PER_CONN = 100;

    var server_threads: [CONNS]std.Thread = undefined;
    for (0..CONNS) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveSmallConn, .{ &server, listener.fd });
    }

    var total_ok = std.atomic.Value(u32).init(0);
    var client_threads: [CONNS]std.Thread = undefined;
    const start = nowMs();

    for (0..CONNS) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(port: u16, ok: *std.atomic.Value(u32)) void {
                var sock = TcpSocket.connectTo(port) catch return;
                defer sock.close();

                var reader = BufferedReader(8192).init(&sock);
                for (0..REQS_PER_CONN) |_| {
                    sendRaw(&sock, GET_REQUEST) catch return;
                    if (reader.readOneResponse() catch false) {
                        _ = ok.fetchAdd(1, .monotonic);
                    }
                }
            }
        }.run, .{ listener.port, &total_ok });
    }

    for (&client_threads) |*ct| ct.join();
    for (&server_threads) |*st| st.join();

    const elapsed = nowMs() - start;
    const ok = total_ok.load(.monotonic);
    const expected: u32 = CONNS * REQS_PER_CONN;
    print("\n[bench] HTTP concurrent-keepalive: {d}x{d} = {d}/{d} req in {d}ms\n", .{ CONNS, REQS_PER_CONN, ok, expected, elapsed });
    try testing.expectEqual(expected, ok);
}
