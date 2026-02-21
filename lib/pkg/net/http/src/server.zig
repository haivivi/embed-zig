const std = @import("std");
const mem = std.mem;
const Allocator = std.mem.Allocator;

const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");

const Request = request_mod.Request;
const Response = response_mod.Response;
const Route = router_mod.Route;
const Handler = router_mod.Handler;

pub const Config = struct {
    read_buf_size: usize = 8192,
    write_buf_size: usize = 4096,
    max_requests_per_conn: usize = 100,
};

/// HTTP/1.1 Server generic over Socket type.
///
/// Socket must implement recv/send/close (trait.socket interface).
/// User controls the accept loop; server handles per-connection request/response.
///
/// Example:
///   const HttpServer = http.Server(Socket, .{ .read_buf_size = 8192 });
///   var server = HttpServer.init(allocator, &routes);
///   while (try listener.accept()) |conn| {
///       wg.go(server.serveConn, .{conn});
///   }
pub fn Server(comptime Socket: type, comptime config: Config) type {
    return struct {
        const Self = @This();

        routes: []const Route,
        allocator: Allocator,

        pub fn init(allocator: Allocator, routes: []const Route) Self {
            return .{
                .routes = routes,
                .allocator = allocator,
            };
        }

        /// Serve a single connection. Call in a spawned task.
        /// Supports HTTP/1.1 keep-alive: loops until connection close or limit reached.
        pub fn serveConn(self: *const Self, socket: Socket) void {
            var sock = socket;
            defer sock.close();

            const read_buf = self.allocator.alloc(u8, config.read_buf_size) catch return;
            defer self.allocator.free(read_buf);

            const write_buf = self.allocator.alloc(u8, config.write_buf_size) catch return;
            defer self.allocator.free(write_buf);

            var buffered: usize = 0;
            var requests_served: usize = 0;

            var need_more_data = false;

            while (requests_served < config.max_requests_per_conn) {
                // Read data until we can attempt a parse.
                // First iteration: wait for header terminator "\r\n\r\n".
                // After Incomplete (partial body): force at least one recv before retrying parse.
                while (need_more_data or mem.indexOf(u8, read_buf[0..buffered], "\r\n\r\n") == null) {
                    if (buffered >= read_buf.len) break;

                    const n = sock.recv(read_buf[buffered..]) catch |err| {
                        switch (err) {
                            error.Timeout => break,
                            error.Closed => return,
                            else => return,
                        }
                    };
                    if (n == 0) return;
                    buffered += n;
                    need_more_data = false;
                }

                const result = request_mod.parse(read_buf[0..buffered]) catch |err| {
                    switch (err) {
                        error.Incomplete => {
                            if (buffered >= read_buf.len) {
                                sendError(&sock, write_buf, 413);
                                return;
                            }
                            need_more_data = true;
                            continue;
                        },
                        else => {
                            sendError(&sock, write_buf, 400);
                            return;
                        },
                    }
                };

                var req = result.request;
                var resp = Response{
                    .write_buf = write_buf,
                    .write_fn = socketWriteFn(Socket),
                    .write_ctx = @ptrCast(&sock),
                };

                const route_match = router_mod.match(self.routes, req.method, req.path);
                switch (route_match.result) {
                    .found => route_match.handler.?(&req, &resp),
                    .not_found => resp.sendStatus(404),
                    .method_not_allowed => resp.sendStatus(405),
                }

                requests_served += 1;

                if (req.header("Connection")) |conn_header| {
                    if (std.ascii.eqlIgnoreCase(conn_header, "close")) return;
                }

                const consumed = result.consumed;
                if (consumed < buffered) {
                    mem.copyForwards(u8, read_buf[0 .. buffered - consumed], read_buf[consumed..buffered]);
                    buffered -= consumed;
                } else {
                    buffered = 0;
                }
            }
        }

        fn sendError(sock: *Socket, write_buf: []u8, code: u16) void {
            var resp = Response{
                .write_buf = write_buf,
                .write_fn = socketWriteFn(Socket),
                .write_ctx = @ptrCast(sock),
            };
            resp.sendStatus(code);
        }
    };
}

fn socketWriteFn(comptime Socket: type) *const fn (*anyopaque, []const u8) Response.WriteError!void {
    return struct {
        fn write(ctx: *anyopaque, data: []const u8) Response.WriteError!void {
            const sock: *Socket = @ptrCast(@alignCast(ctx));
            var sent: usize = 0;
            while (sent < data.len) {
                sent += sock.send(data[sent..]) catch return error.SocketError;
            }
        }
    }.write;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// MockSocket uses pointer-based shared state so that serveConn (which copies
/// the socket value) still reads from / writes to the test's data.
const MockSocket = struct {
    state: *State,

    const State = struct {
        input: []const u8,
        input_pos: usize = 0,
        output: [8192]u8 = undefined,
        output_len: usize = 0,
        closed: bool = false,

        fn getOutput(self: *const State) []const u8 {
            return self.output[0..self.output_len];
        }
    };

    pub fn recv(self: *MockSocket, buf: []u8) !usize {
        const s = self.state;
        if (s.input_pos >= s.input.len) return 0;
        const remaining = s.input[s.input_pos..];
        const n = @min(remaining.len, buf.len);
        @memcpy(buf[0..n], remaining[0..n]);
        s.input_pos += n;
        return n;
    }

    pub fn send(self: *MockSocket, data: []const u8) !usize {
        const s = self.state;
        const end = s.output_len + data.len;
        if (end > s.output.len) return error.SendFailed;
        @memcpy(s.output[s.output_len..end], data);
        s.output_len = end;
        return data.len;
    }

    pub fn close(self: *MockSocket) void {
        self.state.closed = true;
    }
};

fn testHandler(_: *Request, resp: *Response) void {
    _ = resp.contentType("text/plain");
    resp.send("Hello");
}

test "full request-response cycle" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockSocket.State{ .input = raw };
    const socket = MockSocket{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = Server(MockSocket, .{ .read_buf_size = 1024, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(socket);

    const out = state.getOutput();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Type: text/plain\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "Hello"));
    try testing.expect(state.closed);
}

test "keep-alive — multiple requests" {
    const raw =
        "GET /hello HTTP/1.1\r\nHost: localhost\r\n\r\n" ++
        "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockSocket.State{ .input = raw };
    const socket = MockSocket{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = Server(MockSocket, .{ .read_buf_size = 2048, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(socket);

    const out = state.getOutput();
    var count: usize = 0;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, out, pos, "HTTP/1.1 200 OK")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
}

test "Connection: close terminates" {
    const raw = "GET /hello HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n";
    var state = MockSocket.State{ .input = raw };
    const socket = MockSocket{ .state = &state };

    const routes = [_]Route{
        router_mod.get("/hello", testHandler),
    };

    const TestServer = Server(MockSocket, .{ .read_buf_size = 1024, .write_buf_size = 512 });
    const server = TestServer.init(testing.allocator, &routes);
    server.serveConn(socket);

    try testing.expect(state.closed);
    const out = state.getOutput();
    var count: usize = 0;
    var pos: usize = 0;
    while (mem.indexOfPos(u8, out, pos, "HTTP/1.1 200 OK")) |idx| {
        count += 1;
        pos = idx + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}
