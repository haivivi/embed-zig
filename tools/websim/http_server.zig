//! WebSim HTTP Server with Path Routing
//!
//! Serves multiple pages on http://127.0.0.1:<port>:
//!   GET /                    — Dashboard (board list + create)
//!   GET /board/{name}        — Board PCB UI
//!   POST /api/boards         — Create a new board
//!   POST /api/boards/{name}/flash — Upload firmware
//!   GET /api/boards/{name}/firmware — List firmware history
//!   POST /api/boards/{name}/activate — Activate (run) a board
//!   POST /api/boards/{name}/stop — Stop a board
//!   DELETE /api/boards/{name} — Delete a board

const std = @import("std");
const net = std.net;

/// Route handler function type
pub const HandlerFn = *const fn (ctx: *RequestContext) void;

pub const RequestContext = struct {
    stream: net.Stream,
    method: []const u8,
    path: []const u8,
    body: []const u8,

    /// Send an HTTP response
    pub fn respond(self: *RequestContext, status: u16, content_type: []const u8, body: []const u8) void {
        const status_text = switch (status) {
            200 => "OK",
            201 => "Created",
            204 => "No Content",
            400 => "Bad Request",
            404 => "Not Found",
            500 => "Internal Server Error",
            else => "Unknown",
        };
        var hdr_buf: [512]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hdr_buf,
            "HTTP/1.1 {} {s}\r\nContent-Type: {s}\r\nContent-Length: {}\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n",
            .{ status, status_text, content_type, body.len },
        ) catch return;
        _ = self.stream.writeAll(hdr) catch return;
        if (body.len > 0) {
            _ = self.stream.writeAll(body) catch return;
        }
    }

    pub fn respondHtml(self: *RequestContext, body: []const u8) void {
        self.respond(200, "text/html; charset=utf-8", body);
    }

    pub fn respondJson(self: *RequestContext, body: []const u8) void {
        self.respond(200, "application/json", body);
    }

    pub fn respond404(self: *RequestContext) void {
        self.respond(404, "text/plain", "Not Found");
    }
};

pub const Route = struct {
    method: []const u8, // "GET", "POST", "DELETE"
    prefix: []const u8, // path prefix to match
    handler: HandlerFn,
};

pub const HttpServer = struct {
    listener: net.Server,
    port: u16,
    thread: ?std.Thread = null,
    running: bool = true,
    routes: []const Route,

    /// Initialize the HTTP server on a random port.
    pub fn init(routes: []const Route) !HttpServer {
        const addr = net.Address.initIp4(.{ 127, 0, 0, 1 }, 0);
        const server = try addr.listen(.{ .reuse_address = true });
        const bound_port = server.listen_address.getPort();

        std.debug.print("[HTTP] Bound to http://127.0.0.1:{}\n", .{bound_port});

        return HttpServer{
            .listener = server,
            .port = bound_port,
            .routes = routes,
        };
    }

    pub fn startThread(self: *HttpServer) !void {
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
    }

    pub fn getUrl(self: *const HttpServer, buf: []u8) ![:0]const u8 {
        const len = (try std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.port})).len;
        buf[len] = 0;
        return buf[0..len :0];
    }

    pub fn stop(self: *HttpServer) void {
        self.running = false;
        self.listener.deinit();
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn serveLoop(self: *HttpServer) void {
        std.debug.print("[HTTP] Accept loop started\n", .{});
        while (self.running) {
            const conn = self.listener.accept() catch {
                if (!self.running) return;
                std.Thread.sleep(10 * std.time.ns_per_ms);
                continue;
            };

            self.handleConnection(conn.stream);
            conn.stream.close();
        }
    }

    fn handleConnection(self: *HttpServer, stream: net.Stream) void {
        var req_buf: [65536]u8 = undefined; // 64KB for POST bodies
        var total: usize = 0;

        // Read until we have the full headers + body
        while (total < req_buf.len) {
            const n = stream.read(req_buf[total..]) catch return;
            if (n == 0) break;
            total += n;

            // Check if we have headers end
            if (std.mem.indexOf(u8, req_buf[0..total], "\r\n\r\n")) |hdr_end| {
                // Parse Content-Length to know if we need more body
                const headers = req_buf[0..hdr_end];
                var content_length: usize = 0;
                if (std.mem.indexOf(u8, headers, "Content-Length: ")) |cl_start| {
                    const val_start = cl_start + 16;
                    var val_end = val_start;
                    while (val_end < headers.len and headers[val_end] >= '0' and headers[val_end] <= '9') : (val_end += 1) {}
                    content_length = std.fmt.parseInt(usize, headers[val_start..val_end], 10) catch 0;
                }
                // lowercase variant
                if (content_length == 0) {
                    if (std.mem.indexOf(u8, headers, "content-length: ")) |cl_start| {
                        const val_start = cl_start + 16;
                        var val_end = val_start;
                        while (val_end < headers.len and headers[val_end] >= '0' and headers[val_end] <= '9') : (val_end += 1) {}
                        content_length = std.fmt.parseInt(usize, headers[val_start..val_end], 10) catch 0;
                    }
                }

                const body_start = hdr_end + 4;
                const body_received = total - body_start;
                if (body_received >= content_length) break; // Got everything
            }
        }

        if (total == 0) return;
        const req = req_buf[0..total];

        // Parse method and path from first line
        var line_end: usize = 0;
        while (line_end < total and req[line_end] != '\r' and req[line_end] != '\n') : (line_end += 1) {}

        const first_line = req[0..line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const path = parts.next() orelse return;

        // Find body (after \r\n\r\n)
        var body: []const u8 = "";
        if (std.mem.indexOf(u8, req, "\r\n\r\n")) |hdr_end| {
            body = req[hdr_end + 4 ..];
        }

        std.debug.print("[HTTP] {s} {s} (body={} bytes)\n", .{ method, path, body.len });

        var ctx = RequestContext{
            .stream = stream,
            .method = method,
            .path = path,
            .body = body,
        };

        // Match routes
        for (self.routes) |route| {
            if (std.mem.eql(u8, method, route.method) and
                std.mem.startsWith(u8, path, route.prefix))
            {
                route.handler(&ctx);
                return;
            }
        }

        // No route matched
        ctx.respond404();
    }
};
