const std = @import("std");
const mem = std.mem;
const request = @import("request.zig");

pub const Response = struct {
    /// Buffer used for assembling custom headers via setHeader().
    /// The status line and auto-headers are sent from a stack buffer.
    write_buf: []u8,
    pos: usize = 0,
    headers_sent: bool = false,
    status_code: u16 = 200,

    write_fn: *const fn (ctx: *anyopaque, data: []const u8) WriteError!void,
    write_ctx: *anyopaque,

    pub const WriteError = error{
        SocketError,
        BufferOverflow,
    };

    pub fn status(self: *Response, code: u16) *Response {
        self.status_code = code;
        return self;
    }

    /// Append a custom response header. Must be called before send/json/sendStatus.
    /// Headers are buffered in write_buf and flushed when send is called.
    pub fn setHeader(self: *Response, name: []const u8, value: []const u8) *Response {
        if (self.headers_sent) return self;
        self.appendSlice(name);
        self.appendSlice(": ");
        self.appendSlice(value);
        self.appendSlice("\r\n");
        return self;
    }

    pub fn contentType(self: *Response, mime: []const u8) *Response {
        return self.setHeader("Content-Type", mime);
    }

    pub fn send(self: *Response, body: []const u8) void {
        self.sendFull(body, null);
    }

    pub fn json(self: *Response, body: []const u8) void {
        self.sendFull(body, "application/json");
    }

    pub fn sendStatus(self: *Response, code: u16) void {
        self.status_code = code;
        self.sendFull("", null);
    }

    fn sendFull(self: *Response, body: []const u8, content_type_override: ?[]const u8) void {
        if (self.headers_sent) return;
        self.headers_sent = true;

        // 1. Build status line + auto-headers on stack, send first
        var hdr_buf: [256]u8 = undefined;
        var hdr_pos: usize = 0;

        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "HTTP/1.1 ");
        var code_buf: [3]u8 = undefined;
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, writeStatusCode(&code_buf, self.status_code));
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, " ");
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, statusText(self.status_code));
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "\r\n");

        if (content_type_override) |ct| {
            hdr_pos = appendBuf(&hdr_buf, hdr_pos, "Content-Type: ");
            hdr_pos = appendBuf(&hdr_buf, hdr_pos, ct);
            hdr_pos = appendBuf(&hdr_buf, hdr_pos, "\r\n");
        }

        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "Content-Length: ");
        var cl_buf: [20]u8 = undefined;
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, request.writeUsize(&cl_buf, body.len) orelse "0");
        hdr_pos = appendBuf(&hdr_buf, hdr_pos, "\r\n");

        self.write_fn(self.write_ctx, hdr_buf[0..hdr_pos]) catch {};

        // 2. Send custom headers accumulated by setHeader()
        if (self.pos > 0) {
            self.write_fn(self.write_ctx, self.write_buf[0..self.pos]) catch {};
            self.pos = 0;
        }

        // 3. End headers
        self.write_fn(self.write_ctx, "\r\n") catch {};

        // 4. Body
        if (body.len > 0) {
            self.write_fn(self.write_ctx, body) catch {};
        }
    }

    fn appendSlice(self: *Response, data: []const u8) void {
        const available = self.write_buf.len - self.pos;
        const to_copy = @min(data.len, available);
        if (to_copy > 0) {
            @memcpy(self.write_buf[self.pos .. self.pos + to_copy], data[0..to_copy]);
            self.pos += to_copy;
        }
    }
};

fn appendBuf(buf: []u8, pos: usize, data: []const u8) usize {
    const available = buf.len - pos;
    const to_copy = @min(data.len, available);
    if (to_copy > 0) {
        @memcpy(buf[pos .. pos + to_copy], data[0..to_copy]);
    }
    return pos + to_copy;
}

fn writeStatusCode(buf: *[3]u8, code: u16) []const u8 {
    buf[0] = @intCast(code / 100 + '0');
    buf[1] = @intCast((code / 10) % 10 + '0');
    buf[2] = @intCast(code % 10 + '0');
    return buf;
}

pub fn statusText(code: u16) []const u8 {
    return switch (code) {
        200 => "OK",
        201 => "Created",
        204 => "No Content",
        301 => "Moved Permanently",
        302 => "Found",
        304 => "Not Modified",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        408 => "Request Timeout",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        else => "Unknown",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const TestWriter = struct {
    buf: [4096]u8 = undefined,
    len: usize = 0,

    fn writeFn(ctx: *anyopaque, data: []const u8) Response.WriteError!void {
        const self: *TestWriter = @ptrCast(@alignCast(ctx));
        const end = self.len + data.len;
        if (end > self.buf.len) return error.BufferOverflow;
        @memcpy(self.buf[self.len..end], data);
        self.len = end;
    }

    fn output(self: *const TestWriter) []const u8 {
        return self.buf[0..self.len];
    }
};

test "200 OK with body" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    resp.send("Hello, World!");

    const out = tw.output();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 200 OK\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Length: 13\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "Hello, World!"));
}

test "JSON response" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    resp.json("{\"status\":\"ok\"}");

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "Content-Type: application/json\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "{\"status\":\"ok\"}"));
}

test "404 sendStatus" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    resp.sendStatus(404);

    const out = tw.output();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
    try testing.expect(mem.indexOf(u8, out, "Content-Length: 0\r\n") != null);
}

test "multiple headers" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };

    _ = resp.setHeader("X-Request-Id", "abc123").setHeader("Cache-Control", "no-cache");
    resp.send("ok");

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "X-Request-Id: abc123\r\n") != null);
    try testing.expect(mem.indexOf(u8, out, "Cache-Control: no-cache\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "ok"));
}
