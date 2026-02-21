//! SHA-1 — FIPS 180-4
//!
//! Minimal freestanding implementation for WebSocket handshake
//! (Sec-WebSocket-Accept computation). Not for general crypto use.

pub const digest_length = 20;
pub const block_length = 64;

state: [5]u32,
buf: [block_length]u8,
buf_len: usize,
total_len: u64,

const Self = @This();

pub fn init() Self {
    return .{
        .state = .{
            0x67452301,
            0xEFCDAB89,
            0x98BADCFE,
            0x10325476,
            0xC3D2E1F0,
        },
        .buf = undefined,
        .buf_len = 0,
        .total_len = 0,
    };
}

pub fn update(self: *Self, data: []const u8) void {
    var input = data;
    self.total_len += input.len;

    // Fill partial block
    if (self.buf_len > 0) {
        const needed = block_length - self.buf_len;
        if (input.len < needed) {
            @memcpy(self.buf[self.buf_len..][0..input.len], input);
            self.buf_len += input.len;
            return;
        }
        @memcpy(self.buf[self.buf_len..][0..needed], input[0..needed]);
        processBlock(&self.state, &self.buf);
        input = input[needed..];
        self.buf_len = 0;
    }

    // Process full blocks
    while (input.len >= block_length) {
        processBlock(&self.state, input[0..block_length]);
        input = input[block_length..];
    }

    // Buffer remaining
    if (input.len > 0) {
        @memcpy(self.buf[0..input.len], input);
        self.buf_len = input.len;
    }
}

pub fn final(self: *Self) [digest_length]u8 {
    // Padding: append 1-bit, then zeros, then 64-bit big-endian length
    const total_bits: u64 = self.total_len * 8;

    // Append 0x80
    self.buf[self.buf_len] = 0x80;
    self.buf_len += 1;

    // If not enough room for 8-byte length, pad and process
    if (self.buf_len > 56) {
        @memset(self.buf[self.buf_len..], 0);
        processBlock(&self.state, &self.buf);
        self.buf_len = 0;
    }

    @memset(self.buf[self.buf_len..56], 0);

    // Append length in bits as big-endian u64
    inline for (0..8) |i| {
        self.buf[56 + i] = @intCast((total_bits >> @intCast((7 - i) * 8)) & 0xFF);
    }
    processBlock(&self.state, &self.buf);

    // Produce digest
    var digest: [digest_length]u8 = undefined;
    inline for (0..5) |i| {
        inline for (0..4) |j| {
            digest[i * 4 + j] = @intCast((self.state[i] >> @intCast((3 - j) * 8)) & 0xFF);
        }
    }
    return digest;
}

pub fn hash(data: []const u8) [digest_length]u8 {
    var h = init();
    h.update(data);
    return h.final();
}

fn processBlock(state: *[5]u32, block: *const [64]u8) void {
    var w: [80]u32 = undefined;

    // Load message schedule
    for (0..16) |i| {
        w[i] = @as(u32, block[i * 4]) << 24 |
            @as(u32, block[i * 4 + 1]) << 16 |
            @as(u32, block[i * 4 + 2]) << 8 |
            @as(u32, block[i * 4 + 3]);
    }
    for (16..80) |i| {
        w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];

    for (0..80) |i| {
        var f: u32 = undefined;
        var k: u32 = undefined;

        if (i < 20) {
            f = (b & c) | ((~b) & d);
            k = 0x5A827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ED9EBA1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8F1BBCDC;
        } else {
            f = b ^ c ^ d;
            k = 0xCA62C1D6;
        }

        const temp = rotl(a, 5) +% f +% e +% k +% w[i];
        e = d;
        d = c;
        c = rotl(b, 30);
        b = a;
        a = temp;
    }

    state[0] +%= a;
    state[1] +%= b;
    state[2] +%= c;
    state[3] +%= d;
    state[4] +%= e;
}

fn rotl(x: u32, comptime n: u5) u32 {
    return (x << n) | (x >> @intCast(@as(u6, 32) - n));
}

// ==========================================================================
// Tests
// ==========================================================================

const std = @import("std");

test "SHA1 empty string" {
    const digest = hash("");
    const expected = [_]u8{
        0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d, 0x32, 0x55,
        0xbf, 0xef, 0x95, 0x60, 0x18, 0x90, 0xaf, 0xd8, 0x07, 0x09,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 abc" {
    const digest = hash("abc");
    const expected = [_]u8{
        0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
        0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 WebSocket accept key" {
    // RFC 6455 example: "dGhlIHNhbXBsZSBub25jZQ==" + GUID
    const input = "dGhlIHNhbXBsZSBub25jZQ==" ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const digest = hash(input);
    const expected = [_]u8{
        0xb3, 0x7a, 0x4f, 0x2c, 0xc0, 0x62, 0x4f, 0x16, 0x90, 0xf6,
        0x46, 0x06, 0xcf, 0x38, 0x59, 0x45, 0xb2, 0xbe, 0xc4, 0xea,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}

test "SHA1 longer than one block" {
    const input = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    const digest = hash(input);
    const expected = [_]u8{
        0x84, 0x98, 0x3e, 0x44, 0x1c, 0x3b, 0xd2, 0x6e, 0xba, 0xae,
        0x4a, 0xa1, 0xf9, 0x51, 0x29, 0xe5, 0xe5, 0x46, 0x70, 0xf1,
    };
    try std.testing.expectEqualSlices(u8, &expected, &digest);
}
