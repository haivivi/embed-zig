const std = @import("std");
const posix = std.posix;
const http = @import("http");
const print = std.debug.print;
const testing = std.testing;

// ============================================================================
// TcpSocket — thin wrapper around posix fd, matching trait.socket interface
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
            .addr = std.mem.nativeToBig(u32, 0x7f000001), // 127.0.0.1
        };
        try posix.connect(sock.fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
        return sock;
    }
};

// ============================================================================
// Test Helpers
// ============================================================================

const HttpServer = http.Server(TcpSocket, .{
    .read_buf_size = 8192,
    .write_buf_size = 4096,
    .max_requests_per_conn = 100,
});

fn startListener() !struct { fd: posix.socket_t, port: u16 } {
    const fd = try posix.socket(posix.AF.INET, posix.SOCK.STREAM, 0);
    errdefer posix.close(fd);

    const enable: u32 = 1;
    try posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.REUSEADDR, std.mem.asBytes(&enable));

    const addr = posix.sockaddr.in{
        .family = posix.AF.INET,
        .port = 0, // OS picks port
        .addr = std.mem.nativeToBig(u32, 0x7f000001),
    };
    try posix.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try posix.listen(fd, 128);

    // Get assigned port
    var bound_addr: posix.sockaddr.in = undefined;
    var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.in);
    try posix.getsockname(fd, @ptrCast(&bound_addr), &addr_len);
    const port = std.mem.bigToNative(u16, bound_addr.port);

    return .{ .fd = fd, .port = port };
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

fn recvAll(sock: *TcpSocket, buf: []u8) ![]const u8 {
    var total: usize = 0;
    while (total < buf.len) {
        const n = posix.recv(sock.fd, buf[total..], 0) catch break;
        if (n == 0) break;
        total += n;

        // Check if we got a complete response (headers + body)
        if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |hdr_end| {
            // Look for Content-Length to determine if body is complete
            if (std.mem.indexOf(u8, buf[0..hdr_end], "Content-Length: ")) |cl_start| {
                const val_start = cl_start + "Content-Length: ".len;
                const val_end = std.mem.indexOfPos(u8, buf[0..hdr_end], val_start, "\r\n") orelse hdr_end;
                const cl_str = buf[val_start..val_end];
                const content_len = std.fmt.parseUnsigned(usize, cl_str, 10) catch 0;
                const body_start = hdr_end + 4;
                if (total >= body_start + content_len) break;
            } else {
                break;
            }
        }
    }
    return buf[0..total];
}

fn expectStatus(response_data: []const u8, expected_code: u16) !void {
    var code_buf: [3]u8 = undefined;
    code_buf[0] = @intCast(expected_code / 100 + '0');
    code_buf[1] = @intCast((expected_code / 10) % 10 + '0');
    code_buf[2] = @intCast(expected_code % 10 + '0');

    var expected: [12]u8 = undefined;
    @memcpy(expected[0..9], "HTTP/1.1 ");
    @memcpy(expected[9..12], &code_buf);

    if (!std.mem.startsWith(u8, response_data, expected[0..12])) {
        print("Expected status {d}, got: {s}\n", .{ expected_code, response_data[0..@min(response_data.len, 30)] });
        return error.TestUnexpectedResult;
    }
}

fn extractBody(response_data: []const u8) []const u8 {
    const hdr_end = std.mem.indexOf(u8, response_data, "\r\n\r\n") orelse return "";
    return response_data[hdr_end + 4 ..];
}

// ============================================================================
// Route Handlers
// ============================================================================

fn handleGetStatus(_: *http.Request, resp: *http.Response) void {
    resp.json("{\"status\":\"ok\"}");
}

fn handlePostData(req: *http.Request, resp: *http.Response) void {
    _ = resp.status(201);
    if (req.body) |body| {
        _ = resp.contentType("application/octet-stream");
        resp.send(body);
    } else {
        resp.send("");
    }
}

fn handleEcho(req: *http.Request, resp: *http.Response) void {
    if (req.body) |body| {
        _ = resp.contentType("application/json");
        resp.send(body);
    } else {
        resp.sendStatus(400);
    }
}

const embedded_files = [_]http.EmbeddedFile{
    .{ .path = "/static/app.js", .data = "console.log('hello');", .mime = "application/javascript" },
    .{ .path = "/static/style.css", .data = "body { margin: 0; }", .mime = "text/css" },
};

const routes = [_]http.Route{
    http.get("/api/status", handleGetStatus),
    http.post("/api/data", handlePostData),
    http.post("/api/echo", handleEcho),
    http.prefix("/static/", http.static.serveEmbedded(&embedded_files)),
};

fn serveOneConnection(server: *const HttpServer, listener_fd: posix.socket_t) void {
    const conn = acceptOne(listener_fd) catch return;
    server.serveConn(conn);
}

// ============================================================================
// E1: Real TCP request-response
// ============================================================================

test "E1: real TCP server request-response" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = HttpServer.init(testing.allocator, &routes);

    // Test 1: GET /api/status → 200 + JSON
    {
        const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
        defer t.join();

        var sock = try TcpSocket.connectTo(listener.port);
        defer sock.close();
        try sendRaw(&sock, "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 200);
        try testing.expect(std.mem.indexOf(u8, resp, "application/json") != null);
        try testing.expectEqualStrings("{\"status\":\"ok\"}", extractBody(resp));
    }

    // Test 2: POST /api/data → 201
    {
        const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
        defer t.join();

        var sock = try TcpSocket.connectTo(listener.port);
        defer sock.close();
        try sendRaw(&sock, "POST /api/data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nConnection: close\r\n\r\ntest");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 201);
    }

    // Test 3: GET /nonexistent → 404
    {
        const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
        defer t.join();

        var sock = try TcpSocket.connectTo(listener.port);
        defer sock.close();
        try sendRaw(&sock, "GET /nonexistent HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 404);
    }

    // Test 4: POST /api/status → 405 (GET-only route)
    {
        const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
        defer t.join();

        var sock = try TcpSocket.connectTo(listener.port);
        defer sock.close();
        try sendRaw(&sock, "POST /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 405);
    }
}

// ============================================================================
// E2: 10 concurrent connections
// ============================================================================

test "E2: 10 concurrent connections" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = HttpServer.init(testing.allocator, &routes);
    const N = 10;

    var server_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        server_threads[i] = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
    }

    var results: [N]bool = [_]bool{false} ** N;
    var client_threads: [N]std.Thread = undefined;
    for (0..N) |i| {
        client_threads[i] = try std.Thread.spawn(.{}, struct {
            fn run(port: u16, result: *bool) void {
                var sock = TcpSocket.connectTo(port) catch return;
                defer sock.close();
                sendRaw(&sock, "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") catch return;

                var buf: [4096]u8 = undefined;
                const resp = recvAll(&sock, &buf) catch return;
                if (std.mem.startsWith(u8, resp, "HTTP/1.1 200")) {
                    result.* = true;
                }
            }
        }.run, .{ listener.port, &results[i] });
    }

    for (&client_threads) |*t| t.join();
    for (&server_threads) |*t| t.join();

    var success_count: usize = 0;
    for (results) |r| {
        if (r) success_count += 1;
    }
    try testing.expectEqual(@as(usize, N), success_count);
}

// ============================================================================
// E3: Large body POST (4KB)
// ============================================================================

test "E3: 4KB body POST echo" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = HttpServer.init(testing.allocator, &routes);

    const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
    defer t.join();

    // Build 4KB JSON body
    var body_buf: [4096]u8 = undefined;
    @memset(&body_buf, 'A');
    @memcpy(body_buf[0..2], "{\"");
    @memcpy(body_buf[4094..4096], "\"}");
    const body: []const u8 = &body_buf;

    var sock = try TcpSocket.connectTo(listener.port);
    defer sock.close();

    // Build request with Content-Length header
    var req_buf: [256]u8 = undefined;
    const header = std.fmt.bufPrint(&req_buf, "POST /api/echo HTTP/1.1\r\nHost: localhost\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch unreachable;
    try sendRaw(&sock, header);
    try sendRaw(&sock, body);

    var recv_buf: [8192]u8 = undefined;
    const resp = try recvAll(&sock, &recv_buf);
    try expectStatus(resp, 200);

    const resp_body = extractBody(resp);
    try testing.expectEqual(body.len, resp_body.len);
    try testing.expect(std.mem.eql(u8, body, resp_body));
}

// ============================================================================
// E4: Keep-alive + pipeline (5 requests on single connection)
// ============================================================================

test "E4: keep-alive 5 requests then close" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = HttpServer.init(testing.allocator, &routes);
    const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
    defer t.join();

    var sock = try TcpSocket.connectTo(listener.port);
    defer sock.close();

    // Send 5 keep-alive requests + 1 close
    for (0..5) |_| {
        try sendRaw(&sock, "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 200);
    }

    // Final request with Connection: close
    try sendRaw(&sock, "GET /api/status HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    var buf: [4096]u8 = undefined;
    const resp = try recvAll(&sock, &buf);
    try expectStatus(resp, 200);

    // Connection should be closed by server now; next recv should return 0
    var extra: [1]u8 = undefined;
    const n = posix.recv(sock.fd, &extra, 0) catch 0;
    try testing.expectEqual(@as(usize, 0), n);
}

// ============================================================================
// E5: Static embedded files
// ============================================================================

test "E5: static embedded file serving" {
    const listener = try startListener();
    defer posix.close(listener.fd);

    const server = HttpServer.init(testing.allocator, &routes);

    // Test 1: GET /static/app.js → 200 + correct MIME + content
    {
        const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
        defer t.join();

        var sock = try TcpSocket.connectTo(listener.port);
        defer sock.close();
        try sendRaw(&sock, "GET /static/app.js HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 200);
        try testing.expect(std.mem.indexOf(u8, resp, "application/javascript") != null);
        try testing.expectEqualStrings("console.log('hello');", extractBody(resp));
    }

    // Test 2: GET /static/nonexistent → 404
    {
        const t = try std.Thread.spawn(.{}, serveOneConnection, .{ &server, listener.fd });
        defer t.join();

        var sock = try TcpSocket.connectTo(listener.port);
        defer sock.close();
        try sendRaw(&sock, "GET /static/nonexistent HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");

        var buf: [4096]u8 = undefined;
        const resp = try recvAll(&sock, &buf);
        try expectStatus(resp, 404);
    }
}
