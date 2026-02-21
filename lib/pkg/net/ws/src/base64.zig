//! Base64 Encoder/Decoder — RFC 4648
//!
//! Minimal freestanding implementation for WebSocket handshake.
//! Only standard alphabet (no URL-safe variant).

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Calculate encoded length (with padding).
pub fn encodedLen(input_len: usize) usize {
    return ((input_len + 2) / 3) * 4;
}

/// Encode `input` into `out`. Returns the slice of `out` that was written.
/// `out` must be at least `encodedLen(input.len)` bytes.
pub fn encode(out: []u8, input: []const u8) []const u8 {
    const len = encodedLen(input.len);
    var pos: usize = 0;
    var i: usize = 0;

    while (i + 3 <= input.len) : (i += 3) {
        const b0 = input[i];
        const b1 = input[i + 1];
        const b2 = input[i + 2];

        out[pos] = alphabet[b0 >> 2];
        out[pos + 1] = alphabet[((b0 & 0x03) << 4) | (b1 >> 4)];
        out[pos + 2] = alphabet[((b1 & 0x0F) << 2) | (b2 >> 6)];
        out[pos + 3] = alphabet[b2 & 0x3F];
        pos += 4;
    }

    const remaining = input.len - i;
    if (remaining == 1) {
        out[pos] = alphabet[input[i] >> 2];
        out[pos + 1] = alphabet[(input[i] & 0x03) << 4];
        out[pos + 2] = '=';
        out[pos + 3] = '=';
    } else if (remaining == 2) {
        out[pos] = alphabet[input[i] >> 2];
        out[pos + 1] = alphabet[((input[i] & 0x03) << 4) | (input[i + 1] >> 4)];
        out[pos + 2] = alphabet[(input[i + 1] & 0x0F) << 2];
        out[pos + 3] = '=';
    }

    return out[0..len];
}

/// Calculate maximum decoded length (before removing padding).
pub fn decodedLen(input_len: usize) usize {
    return (input_len / 4) * 3;
}

pub const DecodeError = error{
    InvalidCharacter,
    InvalidPadding,
};

/// Decode base64 `input` into `out`. Returns the slice of `out` written.
pub fn decode(out: []u8, input: []const u8) DecodeError![]const u8 {
    if (input.len % 4 != 0) return error.InvalidPadding;

    var pos: usize = 0;
    var i: usize = 0;

    while (i < input.len) : (i += 4) {
        const a = try decodeChar(input[i]);
        const b = try decodeChar(input[i + 1]);

        out[pos] = (a << 2) | (b >> 4);
        pos += 1;

        if (input[i + 2] != '=') {
            const c = try decodeChar(input[i + 2]);
            out[pos] = (b << 4) | (c >> 2);
            pos += 1;

            if (input[i + 3] != '=') {
                const d = try decodeChar(input[i + 3]);
                out[pos] = (c << 6) | d;
                pos += 1;
            }
        }
    }

    return out[0..pos];
}

fn decodeChar(c: u8) DecodeError!u8 {
    if (c >= 'A' and c <= 'Z') return @intCast(c - 'A');
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 26);
    if (c >= '0' and c <= '9') return @intCast(c - '0' + 52);
    if (c == '+') return 62;
    if (c == '/') return 63;
    return error.InvalidCharacter;
}

// ==========================================================================
// Tests
// ==========================================================================

const std = @import("std");

test "encode empty" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "", encode(&out, ""));
}

test "encode single byte" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "YQ==", encode(&out, "a"));
}

test "encode two bytes" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "YWI=", encode(&out, "ab"));
}

test "encode three bytes" {
    var out: [4]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "YWJj", encode(&out, "abc"));
}

test "encode WebSocket key" {
    // 16 bytes → 24 base64 chars
    const key = [16]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10 };
    var out: [24]u8 = undefined;
    const encoded = encode(&out, &key);
    try std.testing.expectEqual(@as(usize, 24), encoded.len);
}

test "RFC 6455 Sec-WebSocket-Accept" {
    // The expected accept value from RFC 6455 Section 4.2.2 example
    const sha1 = @import("sha1.zig");
    const key_with_guid = "dGhlIHNhbXBsZSBub25jZQ==" ++ "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    const digest = sha1.hash(key_with_guid);
    var out: [28]u8 = undefined;
    const accept = encode(&out, &digest);
    try std.testing.expectEqualSlices(u8, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", accept);
}

test "decode roundtrip" {
    const original = "Hello, WebSocket!";
    var enc_buf: [encodedLen(original.len)]u8 = undefined;
    const encoded = encode(&enc_buf, original);

    var dec_buf: [original.len]u8 = undefined;
    const decoded = try decode(&dec_buf, encoded);
    try std.testing.expectEqualSlices(u8, original, decoded);
}
