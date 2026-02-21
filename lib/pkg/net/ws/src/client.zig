//! WebSocket Client — RFC 6455
//!
//! Generic over Socket type. Works with plain TCP or TLS sockets.
//! Supports text, binary, ping/pong, and close frames.
//!
//! Limitations:
//! - No message fragmentation (continuation frames). Messages must fit in a
//!   single frame. Sufficient for Doubao Realtime and most WebSocket APIs.
//!
//! ## Usage
//!
//! ```zig
//! var client = try ws.Client(Socket).init(allocator, &socket, .{
//!     .host = "echo.websocket.org",
//!     .path = "/",
//!     .rng_fill = crypto.Rng.fill,
//! });
//! defer client.deinit();
//!
//! try client.sendText("hello");
//! while (try client.recv()) |msg| {
//!     // msg.payload is valid until next recv()
//! }
//! ```

const Allocator = @import("std").mem.Allocator;
const frame = @import("frame.zig");
const handshake_mod = @import("handshake.zig");

pub const Message = struct {
    type: MessageType,
    payload: []const u8,
};

pub const MessageType = enum {
    text,
    binary,
    ping,
    pong,
    close,
};

pub fn Client(comptime Socket: type) type {
    return struct {
        const Self = @This();

        pub const InitOptions = struct {
            host: []const u8,
            port: u16 = 443,
            path: []const u8 = "/",
            extra_headers: ?[]const [2][]const u8 = null,
            rng_fill: *const fn ([]u8) void,
            buffer_size: usize = 4096,
            mask_chunk_size: usize = 512,
        };

        socket: *Socket,
        read_buf: []u8,
        read_start: usize,
        read_end: usize,
        mask_buf: []u8,
        allocator: Allocator,
        rng_fill: *const fn ([]u8) void,
        state: State,

        const State = enum {
            open,
            closing,
            closed,
        };

        /// Initialize a WebSocket client by performing the HTTP Upgrade handshake.
        pub fn init(
            allocator: Allocator,
            socket: *Socket,
            opts: InitOptions,
        ) !Self {
            const read_buf = try allocator.alloc(u8, opts.buffer_size);
            errdefer allocator.free(read_buf);

            const mask_buf = try allocator.alloc(u8, opts.mask_chunk_size);
            errdefer allocator.free(mask_buf);

            const leftover = handshake_mod.performHandshake(
                socket,
                opts.host,
                opts.path,
                opts.extra_headers,
                read_buf,
                opts.rng_fill,
            ) catch |err| switch (err) {
                error.HandshakeFailed => return error.HandshakeFailed,
                error.InvalidResponse => return error.InvalidResponse,
                error.InvalidAcceptKey => return error.InvalidAcceptKey,
                error.ResponseTooLarge => return error.ResponseTooLarge,
                error.SendFailed => return error.SendFailed,
                error.RecvFailed => return error.RecvFailed,
                error.Closed => return error.Closed,
            };

            return .{
                .socket = socket,
                .read_buf = read_buf,
                .read_start = 0,
                .read_end = leftover,
                .mask_buf = mask_buf,
                .allocator = allocator,
                .rng_fill = opts.rng_fill,
                .state = .open,
            };
        }

        /// Initialize without performing handshake. For testing or pre-handshaked connections.
        pub fn initRaw(
            allocator: Allocator,
            socket: *Socket,
            opts: struct {
                rng_fill: *const fn ([]u8) void,
                buffer_size: usize = 4096,
                mask_chunk_size: usize = 512,
            },
        ) !Self {
            const read_buf = try allocator.alloc(u8, opts.buffer_size);
            errdefer allocator.free(read_buf);

            const mask_buf = try allocator.alloc(u8, opts.mask_chunk_size);
            errdefer allocator.free(mask_buf);

            return .{
                .socket = socket,
                .read_buf = read_buf,
                .read_start = 0,
                .read_end = 0,
                .mask_buf = mask_buf,
                .allocator = allocator,
                .rng_fill = opts.rng_fill,
                .state = .open,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.mask_buf);
            self.allocator.free(self.read_buf);
            self.state = .closed;
        }

        /// Send a text frame.
        pub fn sendText(self: *Self, data: []const u8) !void {
            try self.sendFrame(.text, data);
        }

        /// Send a binary frame.
        pub fn sendBinary(self: *Self, data: []const u8) !void {
            try self.sendFrame(.binary, data);
        }

        /// Send a ping frame.
        pub fn sendPing(self: *Self) !void {
            try self.sendFrame(.ping, "");
        }

        /// Send a pong frame.
        pub fn sendPong(self: *Self, data: []const u8) !void {
            try self.sendFrame(.pong, data);
        }

        /// Send a close frame with a status code.
        pub fn sendClose(self: *Self, code: u16) !void {
            const payload = [2]u8{
                @intCast(code >> 8),
                @intCast(code & 0xFF),
            };
            try self.sendFrame(.close, &payload);
            self.state = .closing;
        }

        /// Receive the next message. Returns null on connection close.
        /// The returned payload slice is valid until the next call to recv().
        ///
        /// Automatically responds to ping frames with pong.
        ///
        /// Note: fragmented messages (continuation frames) are not supported.
        /// Each message must fit in a single frame.
        pub fn recv(self: *Self) !?Message {
            while (true) {
                if (try self.tryParseFrame()) |msg| {
                    return msg;
                }

                if (self.state == .closed) return null;

                try self.readMore();
            }
        }

        /// Close the connection gracefully.
        pub fn close(self: *Self) void {
            if (self.state == .open) {
                self.sendClose(1000) catch {};
            }
            self.state = .closed;
        }

        // ==================================================================
        // Internal
        // ==================================================================

        fn sendFrame(self: *Self, opcode: frame.Opcode, payload: []const u8) !void {
            if (self.state == .closed) return error.Closed;

            var mask_key: [4]u8 = undefined;
            self.rng_fill(&mask_key);

            var hdr_buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
            const hdr_len = frame.encodeHeader(&hdr_buf, opcode, payload.len, true, mask_key);

            try sendAll(self.socket, hdr_buf[0..hdr_len]);

            // Stream-mask payload in chunks to avoid modifying caller's buffer
            var offset: usize = 0;
            while (offset < payload.len) {
                const chunk_size = @min(self.mask_buf.len, payload.len - offset);
                @memcpy(self.mask_buf[0..chunk_size], payload[offset..][0..chunk_size]);
                frame.applyMaskOffset(self.mask_buf[0..chunk_size], mask_key, offset);
                try sendAll(self.socket, self.mask_buf[0..chunk_size]);
                offset += chunk_size;
            }
        }

        fn tryParseFrame(self: *Self) !?Message {
            const buffered = self.read_buf[self.read_start..self.read_end];
            if (buffered.len < 2) return null;

            const header = frame.decodeHeader(buffered) catch |err| switch (err) {
                error.TruncatedHeader => return null,
                else => return err,
            };

            // Guard against u64 payload_len overflowing usize on 32-bit targets.
            // Compare as u64 before casting — if it doesn't fit in the buffer, it
            // certainly doesn't fit in usize either.
            if (header.payload_len > buffered.len) return null;
            const payload_len: usize = @intCast(header.payload_len);

            const total_frame_size = header.header_size + payload_len;
            if (buffered.len < total_frame_size) return null;

            const payload_start = self.read_start + header.header_size;
            const payload_end = payload_start + payload_len;

            if (header.masked) {
                frame.applyMask(self.read_buf[payload_start..payload_end], header.mask_key);
            }

            const payload = self.read_buf[payload_start..payload_end];
            self.read_start += total_frame_size;

            switch (header.opcode) {
                .ping => {
                    self.sendPong(payload) catch {};
                    return Message{ .type = .ping, .payload = payload };
                },
                .close => {
                    if (self.state == .open) {
                        self.sendClose(1000) catch {};
                    }
                    self.state = .closed;
                    return null;
                },
                .text => return Message{ .type = .text, .payload = payload },
                .binary => return Message{ .type = .binary, .payload = payload },
                .pong => return Message{ .type = .pong, .payload = payload },
                else => return null,
            }
        }

        fn readMore(self: *Self) !void {
            if (self.read_start > 0) {
                const remaining = self.read_end - self.read_start;
                if (remaining > 0) {
                    copyForward(self.read_buf, self.read_buf[self.read_start..self.read_end]);
                }
                self.read_end = remaining;
                self.read_start = 0;
            }

            if (self.read_end >= self.read_buf.len) return error.ResponseTooLarge;

            const n = self.socket.recv(self.read_buf[self.read_end..]) catch {
                self.state = .closed;
                return error.Closed;
            };
            if (n == 0) {
                self.state = .closed;
                return error.Closed;
            }
            self.read_end += n;
        }
    };
}

/// Copy bytes forward in a potentially overlapping buffer.
/// Used by both client.zig and handshake.zig.
pub fn copyForward(dst: []u8, src: []const u8) void {
    for (src, 0..) |b, i| {
        dst[i] = b;
    }
}

pub fn sendAll(socket: anytype, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = socket.send(data[sent..]) catch return error.SendFailed;
        if (n == 0) return error.Closed;
        sent += n;
    }
}

// ==========================================================================
// Tests
// ==========================================================================

const std = @import("std");

const MockSocket = struct {
    recv_data: []const u8,
    recv_pos: usize = 0,
    sent_buf: [4096]u8 = undefined,
    sent_len: usize = 0,

    fn initMock(recv_data: []const u8) MockSocket {
        return .{ .recv_data = recv_data };
    }

    pub fn send(self: *MockSocket, data: []const u8) !usize {
        if (self.sent_len + data.len > self.sent_buf.len) return error.SendFailed;
        @memcpy(self.sent_buf[self.sent_len..][0..data.len], data);
        self.sent_len += data.len;
        return data.len;
    }

    pub fn recv(self: *MockSocket, buf: []u8) !usize {
        if (self.recv_pos >= self.recv_data.len) return error.Closed;
        const available = self.recv_data.len - self.recv_pos;
        const n = @min(available, buf.len);
        @memcpy(buf[0..n], self.recv_data[self.recv_pos..][0..n]);
        self.recv_pos += n;
        return n;
    }
};

fn deterministicRng(buf: []u8) void {
    for (buf, 0..) |*b, i| {
        b.* = @intCast(i % 256);
    }
}

fn buildServerFrame(allocator: std.mem.Allocator, opcode: frame.Opcode, payload: []const u8) ![]u8 {
    var hdr_buf: [frame.MAX_HEADER_SIZE]u8 = undefined;
    const hdr_len = frame.encodeHeader(&hdr_buf, opcode, payload.len, true, null);
    const total = hdr_len + payload.len;
    const buf = try allocator.alloc(u8, total);
    @memcpy(buf[0..hdr_len], hdr_buf[0..hdr_len]);
    @memcpy(buf[hdr_len..], payload);
    return buf;
}

test "MockSocket send + recv roundtrip" {
    const allocator = std.testing.allocator;

    const server_frame = try buildServerFrame(allocator, .text, "hello");
    defer allocator.free(server_frame);

    var mock = MockSocket.initMock(server_frame);
    var client = try Client(MockSocket).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendText("hello");

    const msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.text, msg.type);
    try std.testing.expectEqualSlices(u8, "hello", msg.payload);
}

test "sendBinary + recv binary" {
    const allocator = std.testing.allocator;
    const binary_data = [_]u8{ 0x00, 0x01, 0x02, 0xFF, 0xFE };

    const server_frame = try buildServerFrame(allocator, .binary, &binary_data);
    defer allocator.free(server_frame);

    var mock = MockSocket.initMock(server_frame);
    var client = try Client(MockSocket).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendBinary(&binary_data);

    const msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.binary, msg.type);
    try std.testing.expectEqualSlices(u8, &binary_data, msg.payload);
}

test "auto pong on ping" {
    const allocator = std.testing.allocator;

    const ping_frame = try buildServerFrame(allocator, .ping, "");
    defer allocator.free(ping_frame);

    const text_frame = try buildServerFrame(allocator, .text, "after_ping");
    defer allocator.free(text_frame);

    const combined = try allocator.alloc(u8, ping_frame.len + text_frame.len);
    defer allocator.free(combined);
    @memcpy(combined[0..ping_frame.len], ping_frame);
    @memcpy(combined[ping_frame.len..], text_frame);

    var mock = MockSocket.initMock(combined);
    var client = try Client(MockSocket).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    const ping_msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.ping, ping_msg.type);

    const sent = mock.sent_buf[0..mock.sent_len];
    try std.testing.expect(sent.len > 0);
    try std.testing.expectEqual(@as(u8, 0x8A), sent[0]);

    const text_msg = (try client.recv()) orelse return error.InvalidResponse;
    try std.testing.expectEqual(MessageType.text, text_msg.type);
    try std.testing.expectEqualSlices(u8, "after_ping", text_msg.payload);
}

test "recv close returns null" {
    const allocator = std.testing.allocator;

    const close_payload = [2]u8{ 0x03, 0xE8 };
    const close_frame = try buildServerFrame(allocator, .close, &close_payload);
    defer allocator.free(close_frame);

    var mock = MockSocket.initMock(close_frame);
    var client = try Client(MockSocket).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    const result = try client.recv();
    try std.testing.expectEqual(@as(?Message, null), result);
}

test "sendClose sends correct close frame" {
    const allocator = std.testing.allocator;

    var mock = MockSocket.initMock("");
    var client = try Client(MockSocket).initRaw(allocator, &mock, .{ .rng_fill = deterministicRng });
    defer client.deinit();

    try client.sendClose(1000);

    const sent = mock.sent_buf[0..mock.sent_len];
    try std.testing.expect(sent.len >= 2);

    try std.testing.expectEqual(@as(u8, 0x88), sent[0]);
    try std.testing.expectEqual(@as(u8, 0x82), sent[1]);

    const mask_key = sent[2..6].*;
    var status_bytes = [2]u8{ sent[6], sent[7] };
    frame.applyMask(&status_bytes, mask_key);

    const status = @as(u16, status_bytes[0]) << 8 | @as(u16, status_bytes[1]);
    try std.testing.expectEqual(@as(u16, 1000), status);
}
