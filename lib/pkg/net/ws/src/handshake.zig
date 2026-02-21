//! WebSocket Handshake — RFC 6455 Section 4
//!
//! Performs the HTTP Upgrade handshake over an existing socket connection.
//! Generates Sec-WebSocket-Key and validates Sec-WebSocket-Accept.

const std = @import("std");
const sha1 = @import("sha1.zig");
const base64 = @import("base64.zig");

pub const Error = error{
    HandshakeFailed,
    InvalidResponse,
    InvalidAcceptKey,
    ResponseTooLarge,
    SendFailed,
    RecvFailed,
    Closed,
};

const ws_guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";

/// Generate the Sec-WebSocket-Accept value for a given key.
/// key must be a 24-byte base64-encoded string.
pub fn computeAcceptKey(key: []const u8, out: *[28]u8) void {
    var h = sha1.init();
    h.update(key);
    h.update(ws_guid);
    const digest = h.final();
    _ = base64.encode(out, &digest);
}

/// Build the HTTP Upgrade request into `buf`. Returns the slice of buf written.
pub fn buildRequest(
    buf: []u8,
    host: []const u8,
    path: []const u8,
    ws_key: []const u8,
    extra_headers: ?[]const [2][]const u8,
) ![]const u8 {
    var writer = BufWriter{ .buf = buf };

    try writer.writeSlice("GET ");
    try writer.writeSlice(path);
    try writer.writeSlice(" HTTP/1.1\r\n");

    try writer.writeSlice("Host: ");
    try writer.writeSlice(host);
    try writer.writeSlice("\r\n");

    try writer.writeSlice("Upgrade: websocket\r\n");
    try writer.writeSlice("Connection: Upgrade\r\n");

    try writer.writeSlice("Sec-WebSocket-Key: ");
    try writer.writeSlice(ws_key);
    try writer.writeSlice("\r\n");

    try writer.writeSlice("Sec-WebSocket-Version: 13\r\n");

    if (extra_headers) |headers| {
        for (headers) |hdr| {
            try writer.writeSlice(hdr[0]);
            try writer.writeSlice(": ");
            try writer.writeSlice(hdr[1]);
            try writer.writeSlice("\r\n");
        }
    }

    try writer.writeSlice("\r\n");
    return buf[0..writer.pos];
}

/// Parse the HTTP response status line + headers. Validates:
/// - Status is 101
/// - Sec-WebSocket-Accept matches expected value
///
/// Returns the number of bytes consumed (including the \r\n\r\n terminator).
/// Returns error.InvalidResponse if the response header is incomplete.
pub fn validateResponse(
    response: []const u8,
    expected_accept: []const u8,
) Error!usize {
    const header_end = findHeaderEnd(response) orelse return error.InvalidResponse;
    const header_data = response[0..header_end];

    // Check status line: "HTTP/1.1 101 ..."
    if (!startsWith(header_data, "HTTP/1.1 101") and !startsWith(header_data, "HTTP/1.0 101"))
        return error.HandshakeFailed;

    // Find Sec-WebSocket-Accept header
    const accept_value = findHeaderValue(header_data, "Sec-WebSocket-Accept") orelse
        return error.InvalidAcceptKey;

    if (!eql(accept_value, expected_accept))
        return error.InvalidAcceptKey;

    // header_end is the index of \r\n\r\n, consume the full terminator
    return header_end + 4;
}

/// Perform the full WebSocket handshake over a socket.
///
/// `rng_fill` is a function that fills a buffer with random bytes
/// (from trait.rng or any platform RNG).
pub fn performHandshake(
    socket: anytype,
    host: []const u8,
    path: []const u8,
    extra_headers: ?[]const [2][]const u8,
    buf: []u8,
    rng_fill: *const fn ([]u8) void,
) Error!usize {
    // Generate 16 random bytes → base64 for Sec-WebSocket-Key
    var key_bytes: [16]u8 = undefined;
    rng_fill(&key_bytes);

    var ws_key: [24]u8 = undefined;
    _ = base64.encode(&ws_key, &key_bytes);

    // Compute expected accept
    var expected_accept: [28]u8 = undefined;
    computeAcceptKey(&ws_key, &expected_accept);

    // Build and send request
    const request = buildRequest(buf, host, path, &ws_key, extra_headers) catch
        return error.SendFailed;

    sendAll(socket, request) catch return error.SendFailed;

    // Read response
    var resp_len: usize = 0;
    while (resp_len < buf.len) {
        const n = socket.recv(buf[resp_len..]) catch |err| switch (err) {
            error.Closed => return error.Closed,
            else => return error.RecvFailed,
        };
        if (n == 0) return error.Closed;
        resp_len += n;

        // Check if we have the full header
        if (findHeaderEnd(buf[0..resp_len])) |_| {
            const consumed = try validateResponse(buf[0..resp_len], &expected_accept);
            // Shift any leftover data (post-handshake frame bytes) to front of buffer
            const leftover = resp_len - consumed;
            if (leftover > 0) {
                copyForward(buf, buf[consumed..resp_len]);
            }
            return leftover;
        }
    }

    return error.ResponseTooLarge;
}

// ==========================================================================
// Helpers
// ==========================================================================

fn sendAll(socket: anytype, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = try socket.send(data[sent..]);
        if (n == 0) return error.Closed;
        sent += n;
    }
}

fn findHeaderEnd(data: []const u8) ?usize {
    if (data.len < 4) return null;
    for (0..data.len - 3) |i| {
        if (data[i] == '\r' and data[i + 1] == '\n' and data[i + 2] == '\r' and data[i + 3] == '\n')
            return i;
    }
    return null;
}

/// Case-insensitive header value lookup.
fn findHeaderValue(header: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < header.len) {
        const line_start = i;
        while (i < header.len and header[i] != '\r') : (i += 1) {}
        const line = header[line_start..i];
        // Skip \r\n
        if (i + 1 < header.len and header[i] == '\r') i += 2;

        if (line.len > name.len and eqlIgnoreCase(line[0..name.len], name) and line[name.len] == ':') {
            var val_start = name.len + 1;
            while (val_start < line.len and line[val_start] == ' ') : (val_start += 1) {}
            return line[val_start..];
        }
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (ca != cb) return false;
    }
    return true;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (toLower(ca) != toLower(cb)) return false;
    }
    return true;
}

fn toLower(c: u8) u8 {
    if (c >= 'A' and c <= 'Z') return c + 32;
    return c;
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    if (haystack.len < prefix.len) return false;
    return eql(haystack[0..prefix.len], prefix);
}

fn copyForward(dst: []u8, src: []const u8) void {
    for (src, 0..) |b, i| {
        dst[i] = b;
    }
}

/// Simple buffer writer (no allocations).
const BufWriter = struct {
    buf: []u8,
    pos: usize = 0,

    const WriteError = error{ResponseTooLarge};

    fn writeSlice(self: *BufWriter, data: []const u8) WriteError!void {
        if (self.pos + data.len > self.buf.len) return error.ResponseTooLarge;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
};

// ==========================================================================
// Tests
// ==========================================================================

test "buildRequest basic" {
    var buf: [512]u8 = undefined;
    const req = try buildRequest(&buf, "echo.websocket.org", "/", "dGhlIHNhbXBsZSBub25jZQ==", null);

    try std.testing.expect(contains(req, "GET / HTTP/1.1\r\n"));
    try std.testing.expect(contains(req, "Host: echo.websocket.org\r\n"));
    try std.testing.expect(contains(req, "Upgrade: websocket\r\n"));
    try std.testing.expect(contains(req, "Connection: Upgrade\r\n"));
    try std.testing.expect(contains(req, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"));
    try std.testing.expect(contains(req, "Sec-WebSocket-Version: 13\r\n"));
    try std.testing.expect(endsWith(req, "\r\n\r\n"));
}

test "validateResponse 101" {
    var expected_accept: [28]u8 = undefined;
    computeAcceptKey("dGhlIHNhbXBsZSBub25jZQ==", &expected_accept);

    var response_buf: [256]u8 = undefined;
    var writer = BufWriter{ .buf = &response_buf };
    try writer.writeSlice("HTTP/1.1 101 Switching Protocols\r\n");
    try writer.writeSlice("Upgrade: websocket\r\n");
    try writer.writeSlice("Connection: Upgrade\r\n");
    try writer.writeSlice("Sec-WebSocket-Accept: ");
    try writer.writeSlice(&expected_accept);
    try writer.writeSlice("\r\n\r\n");

    const consumed = try validateResponse(response_buf[0..writer.pos], &expected_accept);
    try std.testing.expectEqual(writer.pos, consumed);
}

test "validateResponse non-101 error" {
    const resp = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n";
    try std.testing.expectError(error.HandshakeFailed, validateResponse(resp, "dummy_accept_value_1234567"));
}

test "buildRequest extra headers" {
    var buf: [1024]u8 = undefined;
    const headers = [_][2][]const u8{
        .{ "X-Api-App-Key", "test-key" },
        .{ "X-Custom", "value" },
    };
    const req = try buildRequest(&buf, "api.example.com", "/ws", "dGhlIHNhbXBsZSBub25jZQ==", &headers);

    try std.testing.expect(contains(req, "X-Api-App-Key: test-key\r\n"));
    try std.testing.expect(contains(req, "X-Custom: value\r\n"));
    try std.testing.expect(contains(req, "GET /ws HTTP/1.1\r\n"));
}

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (eql(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn endsWith(haystack: []const u8, suffix: []const u8) bool {
    if (haystack.len < suffix.len) return false;
    return eql(haystack[haystack.len - suffix.len ..], suffix);
}
