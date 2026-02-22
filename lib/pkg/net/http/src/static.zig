const std = @import("std");
const mem = std.mem;
const request_mod = @import("request.zig");
const response_mod = @import("response.zig");
const router_mod = @import("router.zig");

const Request = request_mod.Request;
const Response = response_mod.Response;

pub const EmbeddedFile = struct {
    path: []const u8,
    data: []const u8,
    mime: []const u8,
};

/// Serve embedded files (data compiled into the binary via @embedFile).
/// Returns a Handler that matches request path against the file list.
///
/// Usage:
///   const files = [_]static.EmbeddedFile{
///       .{ .path = "/static/app.js", .data = @embedFile("web/app.js"), .mime = "application/javascript" },
///       .{ .path = "/static/style.css", .data = @embedFile("web/style.css"), .mime = "text/css" },
///   };
///   http.prefix("/static/", static.serveEmbedded(&files)),
pub fn serveEmbedded(comptime files: []const EmbeddedFile) router_mod.Handler {
    return struct {
        fn handler(req: *Request, resp: *Response) void {
            for (files) |file| {
                if (mem.eql(u8, req.path, file.path)) {
                    _ = resp.contentType(file.mime);
                    resp.send(file.data);
                    return;
                }
            }
            resp.sendStatus(404);
        }
    }.handler;
}

/// Guess MIME type from file extension.
pub fn mimeFromPath(path: []const u8) []const u8 {
    if (endsWith(path, ".html") or endsWith(path, ".htm")) return "text/html";
    if (endsWith(path, ".css")) return "text/css";
    if (endsWith(path, ".js")) return "application/javascript";
    if (endsWith(path, ".json")) return "application/json";
    if (endsWith(path, ".png")) return "image/png";
    if (endsWith(path, ".jpg") or endsWith(path, ".jpeg")) return "image/jpeg";
    if (endsWith(path, ".gif")) return "image/gif";
    if (endsWith(path, ".svg")) return "image/svg+xml";
    if (endsWith(path, ".ico")) return "image/x-icon";
    if (endsWith(path, ".txt")) return "text/plain";
    if (endsWith(path, ".xml")) return "application/xml";
    if (endsWith(path, ".wasm")) return "application/wasm";
    return "application/octet-stream";
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    return mem.endsWith(u8, haystack, suffix);
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

const test_files = [_]EmbeddedFile{
    .{ .path = "/static/app.js", .data = "console.log('hello');", .mime = "application/javascript" },
    .{ .path = "/static/style.css", .data = "body { margin: 0; }", .mime = "text/css" },
};

test "embedded file hit" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };
    var req = Request{
        .method = .GET,
        .path = "/static/app.js",
        .query = null,
        .version = "HTTP/1.1",
        .header_bytes = "",
        .body = null,
        .content_length = 0,
    };

    const handler = serveEmbedded(&test_files);
    handler(&req, &resp);

    const out = tw.output();
    try testing.expect(mem.indexOf(u8, out, "Content-Type: application/javascript\r\n") != null);
    try testing.expect(mem.endsWith(u8, out, "console.log('hello');"));
}

test "embedded file 404" {
    var tw = TestWriter{};
    var write_buf: [512]u8 = undefined;
    var resp = Response{
        .write_buf = &write_buf,
        .write_fn = TestWriter.writeFn,
        .write_ctx = @ptrCast(&tw),
    };
    var req = Request{
        .method = .GET,
        .path = "/static/nonexistent.js",
        .query = null,
        .version = "HTTP/1.1",
        .header_bytes = "",
        .body = null,
        .content_length = 0,
    };

    const handler = serveEmbedded(&test_files);
    handler(&req, &resp);

    const out = tw.output();
    try testing.expect(mem.startsWith(u8, out, "HTTP/1.1 404 Not Found\r\n"));
}

test "mimeFromPath" {
    try testing.expectEqualStrings("text/html", mimeFromPath("/index.html"));
    try testing.expectEqualStrings("text/css", mimeFromPath("/style.css"));
    try testing.expectEqualStrings("application/javascript", mimeFromPath("/app.js"));
    try testing.expectEqualStrings("application/json", mimeFromPath("/data.json"));
    try testing.expectEqualStrings("image/png", mimeFromPath("/logo.png"));
    try testing.expectEqualStrings("application/octet-stream", mimeFromPath("/unknown.xyz"));
}
