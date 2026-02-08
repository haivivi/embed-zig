//! MQTT Packet Encoding/Decoding Primitives
//!
//! Common encoding functions shared by MQTT 3.1.1 (v4) and 5.0 (v5).
//! All operations work on caller-provided `[]u8` buffers — zero allocation.

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// Maximum MQTT packet size (1MB default, configurable per broker)
pub const max_packet_size: usize = 1024 * 1024;

pub const protocol_name = "MQTT";

// ============================================================================
// Packet Types
// ============================================================================

pub const PacketType = enum(u4) {
    reserved = 0,
    connect = 1,
    connack = 2,
    publish = 3,
    puback = 4,
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
    auth = 15,

    pub fn name(self: PacketType) []const u8 {
        return switch (self) {
            .reserved => "RESERVED",
            .connect => "CONNECT",
            .connack => "CONNACK",
            .publish => "PUBLISH",
            .puback => "PUBACK",
            .pubrec => "PUBREC",
            .pubrel => "PUBREL",
            .pubcomp => "PUBCOMP",
            .subscribe => "SUBSCRIBE",
            .suback => "SUBACK",
            .unsubscribe => "UNSUBSCRIBE",
            .unsuback => "UNSUBACK",
            .pingreq => "PINGREQ",
            .pingresp => "PINGRESP",
            .disconnect => "DISCONNECT",
            .auth => "AUTH",
        };
    }
};

// ============================================================================
// Protocol Version
// ============================================================================

pub const ProtocolVersion = enum(u8) {
    v4 = 4, // MQTT 3.1.1
    v5 = 5, // MQTT 5.0
};

// ============================================================================
// QoS
// ============================================================================

pub const QoS = enum(u2) {
    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,
};

// ============================================================================
// Reason Codes (MQTT 5.0, also used for v4 return codes)
// ============================================================================

pub const ReasonCode = enum(u8) {
    success = 0x00,
    granted_qos_1 = 0x01,
    granted_qos_2 = 0x02,
    disconnect_with_will = 0x04,
    no_matching_subscribers = 0x10,
    no_subscription_existed = 0x11,
    continue_auth = 0x18,
    re_authenticate = 0x19,
    unspecified_error = 0x80,
    malformed_packet = 0x81,
    protocol_error = 0x82,
    implementation_specific = 0x83,
    unsupported_protocol = 0x84,
    client_id_not_valid = 0x85,
    bad_username_password = 0x86,
    not_authorized = 0x87,
    server_unavailable = 0x88,
    server_busy = 0x89,
    banned = 0x8A,
    server_shutting_down = 0x8B,
    bad_auth_method = 0x8C,
    keep_alive_timeout = 0x8D,
    session_taken_over = 0x8E,
    topic_filter_invalid = 0x8F,
    topic_name_invalid = 0x90,
    packet_id_in_use = 0x91,
    packet_id_not_found = 0x92,
    receive_max_exceeded = 0x93,
    topic_alias_invalid = 0x94,
    packet_too_large = 0x95,
    message_rate_too_high = 0x96,
    quota_exceeded = 0x97,
    administrative_action = 0x98,
    payload_format_invalid = 0x99,
    retain_not_supported = 0x9A,
    qos_not_supported = 0x9B,
    use_another_server = 0x9C,
    server_moved = 0x9D,
    shared_sub_not_supported = 0x9E,
    connection_rate_exceeded = 0x9F,
    max_connect_time = 0xA0,
    sub_id_not_supported = 0xA1,
    wildcard_sub_not_supported = 0xA2,
    _,

    pub fn isError(self: ReasonCode) bool {
        return @intFromEnum(self) >= 0x80;
    }
};

/// MQTT 3.1.1 Connect return codes
pub const ConnectReturnCode = enum(u8) {
    accepted = 0x00,
    bad_protocol = 0x01,
    id_rejected = 0x02,
    server_unavailable = 0x03,
    bad_credentials = 0x04,
    not_authorized = 0x05,
    _,
};

// ============================================================================
// Errors
// ============================================================================

pub const Error = error{
    BufferTooSmall,
    MalformedPacket,
    MalformedVariableInt,
    MalformedString,
    UnknownPacketType,
    ProtocolError,
    UnsupportedProtocolVersion,
    PacketTooLarge,
};

// ============================================================================
// Message
// ============================================================================

pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    retain: bool = false,
};

// ============================================================================
// Fixed Header
// ============================================================================

pub const FixedHeader = struct {
    packet_type: PacketType,
    flags: u4,
    remaining_len: u32,
    header_len: usize,
};

/// Encode fixed header into buffer. Returns bytes written.
pub fn encodeFixedHeader(buf: []u8, packet_type: PacketType, flags: u4, remaining_len: u32) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = (@as(u8, @intFromEnum(packet_type)) << 4) | @as(u8, flags);
    const vlen = try encodeVariableInt(buf[1..], remaining_len);
    return 1 + vlen;
}

/// Decode fixed header from buffer.
pub fn decodeFixedHeader(buf: []const u8) Error!FixedHeader {
    if (buf.len < 2) return Error.MalformedPacket;
    const first = buf[0];
    const ptype_raw = first >> 4;
    const flags: u4 = @truncate(first & 0x0F);
    const packet_type: PacketType = @enumFromInt(ptype_raw);
    const vr = try decodeVariableInt(buf[1..]);
    return .{
        .packet_type = packet_type,
        .flags = flags,
        .remaining_len = vr.value,
        .header_len = 1 + vr.len,
    };
}

// ============================================================================
// Variable-Length Integer
// ============================================================================

/// Encode a variable-length integer. Returns bytes written.
pub fn encodeVariableInt(buf: []u8, value: u32) Error!usize {
    var v = value;
    var i: usize = 0;
    while (true) {
        if (i >= buf.len) return Error.BufferTooSmall;
        var byte: u8 = @truncate(v & 0x7F);
        v >>= 7;
        if (v > 0) byte |= 0x80;
        buf[i] = byte;
        i += 1;
        if (v == 0) break;
    }
    return i;
}

/// Decode a variable-length integer. Returns value and bytes consumed.
pub fn decodeVariableInt(buf: []const u8) Error!struct { value: u32, len: usize } {
    var value: u32 = 0;
    var multiplier: u32 = 1;
    var i: usize = 0;
    while (i < 4) {
        if (i >= buf.len) return Error.MalformedVariableInt;
        const byte = buf[i];
        value += @as(u32, byte & 0x7F) * multiplier;
        i += 1;
        if ((byte & 0x80) == 0) return .{ .value = value, .len = i };
        multiplier *= 128;
    }
    return Error.MalformedVariableInt;
}

/// Get encoded size of a variable-length integer.
pub fn variableIntSize(value: u32) usize {
    if (value < 128) return 1;
    if (value < 16384) return 2;
    if (value < 2097152) return 3;
    return 4;
}

// ============================================================================
// 16-bit / 32-bit Integers (big-endian)
// ============================================================================

pub fn encodeU16(buf: []u8, value: u16) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = @truncate(value >> 8);
    buf[1] = @truncate(value & 0xFF);
    return 2;
}

pub fn decodeU16(buf: []const u8) Error!u16 {
    if (buf.len < 2) return Error.MalformedPacket;
    return (@as(u16, buf[0]) << 8) | @as(u16, buf[1]);
}

pub fn encodeU32(buf: []u8, value: u32) Error!usize {
    if (buf.len < 4) return Error.BufferTooSmall;
    buf[0] = @truncate(value >> 24);
    buf[1] = @truncate((value >> 16) & 0xFF);
    buf[2] = @truncate((value >> 8) & 0xFF);
    buf[3] = @truncate(value & 0xFF);
    return 4;
}

pub fn decodeU32(buf: []const u8) Error!u32 {
    if (buf.len < 4) return Error.MalformedPacket;
    return (@as(u32, buf[0]) << 24) |
        (@as(u32, buf[1]) << 16) |
        (@as(u32, buf[2]) << 8) |
        @as(u32, buf[3]);
}

// ============================================================================
// UTF-8 String (2-byte length prefix + data)
// ============================================================================

pub fn encodeString(buf: []u8, str: []const u8) Error!usize {
    if (str.len > 65535) return Error.MalformedString;
    const total = 2 + str.len;
    if (buf.len < total) return Error.BufferTooSmall;
    _ = try encodeU16(buf[0..2], @truncate(str.len));
    @memcpy(buf[2 .. 2 + str.len], str);
    return total;
}

pub fn decodeString(buf: []const u8) Error!struct { str: []const u8, len: usize } {
    if (buf.len < 2) return Error.MalformedString;
    const str_len = try decodeU16(buf[0..2]);
    const total = 2 + @as(usize, str_len);
    if (buf.len < total) return Error.MalformedString;
    return .{ .str = buf[2..total], .len = total };
}

/// Encode binary data (same format as string)
pub fn encodeBinary(buf: []u8, data: []const u8) Error!usize {
    return encodeString(buf, data);
}

/// Decode binary data (same format as string)
pub fn decodeBinary(buf: []const u8) Error!struct { data: []const u8, len: usize } {
    const r = try decodeString(buf);
    return .{ .data = r.str, .len = r.len };
}

// ============================================================================
// Stream Helpers — read exact bytes from a Transport
// ============================================================================

/// Read exactly `buf.len` bytes from transport.
pub fn readFull(transport: anytype, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try transport.recv(buf[total..]);
        if (n == 0) return error.ConnectionClosed;
        total += n;
    }
}

/// Write all bytes to transport.
pub fn writeAll(transport: anytype, data: []const u8) !void {
    var sent: usize = 0;
    while (sent < data.len) {
        const n = try transport.send(data[sent..]);
        if (n == 0) return error.ConnectionClosed;
        sent += n;
    }
}

/// Read a complete MQTT packet from transport into buf.
/// Returns the total packet length (header + payload).
pub fn readPacket(transport: anytype, buf: []u8) !usize {
    // Read first byte
    try readFull(transport, buf[0..1]);

    // Read remaining length (variable int, up to 4 bytes)
    var remaining_len: u32 = 0;
    var multiplier: u32 = 1;
    var header_len: usize = 1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try readFull(transport, buf[header_len .. header_len + 1]);
        const byte = buf[header_len];
        header_len += 1;
        remaining_len += @as(u32, byte & 0x7F) * multiplier;
        if ((byte & 0x80) == 0) break;
        multiplier *= 128;
    }

    const total = header_len + remaining_len;
    if (total > buf.len) return error.PacketTooLarge;

    // Read remaining payload
    if (remaining_len > 0) {
        try readFull(transport, buf[header_len..total]);
    }

    return total;
}

// ============================================================================
// Packet Building Helper
// ============================================================================

/// Build a complete packet: encodes fixed header + copies payload.
/// Returns total bytes written.
pub fn buildPacket(buf: []u8, packet_type: PacketType, flags: u4, payload: []const u8) Error!usize {
    const remaining: u32 = @truncate(payload.len);
    const header_size = 1 + variableIntSize(remaining);
    const total = header_size + payload.len;
    if (buf.len < total) return Error.BufferTooSmall;

    const hlen = try encodeFixedHeader(buf, packet_type, flags, remaining);
    @memcpy(buf[hlen .. hlen + payload.len], payload);
    return total;
}

// ============================================================================
// PacketBuffer — dynamic buffer with small-inline + heap fallback
// ============================================================================

const Allocator = std.mem.Allocator;

/// Dynamic packet buffer. Uses an inline 4KB buffer for common small packets,
/// falls back to heap allocation for large packets (up to max_packet_size).
pub const PacketBuffer = struct {
    small: [4096]u8 = undefined,
    heap_buf: ?[]u8 = null,
    len: usize = 0,
    allocator: Allocator,

    pub fn init(allocator: Allocator) PacketBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PacketBuffer) void {
        self.release();
    }

    /// Get a buffer of at least `size` bytes. Returns a usable slice.
    pub fn acquire(self: *PacketBuffer, size: usize) ![]u8 {
        if (size <= self.small.len) {
            self.len = size;
            return self.small[0..size];
        }
        // Need heap allocation
        if (self.heap_buf) |hb| {
            if (hb.len >= size) {
                self.len = size;
                return hb[0..size];
            }
            self.allocator.free(hb);
        }
        const buf = try self.allocator.alloc(u8, size);
        self.heap_buf = buf;
        self.len = size;
        return buf[0..size];
    }

    /// Release heap buffer (inline buffer is always available).
    pub fn release(self: *PacketBuffer) void {
        if (self.heap_buf) |hb| {
            self.allocator.free(hb);
            self.heap_buf = null;
        }
        self.len = 0;
    }

    /// Get the current buffer slice (after acquire or readPacket).
    pub fn slice(self: *PacketBuffer) []u8 {
        if (self.heap_buf) |hb| {
            if (self.len > self.small.len) return hb[0..self.len];
        }
        return self.small[0..self.len];
    }
};

/// Read a complete MQTT packet using PacketBuffer (supports large packets).
/// Returns the total packet length. Use `pkt_buf.slice()` to access the data.
pub fn readPacketBuf(transport: anytype, pkt_buf: *PacketBuffer) !usize {
    // Read first byte into small buffer
    try readFull(transport, pkt_buf.small[0..1]);

    // Read remaining length (variable int, up to 4 bytes)
    var remaining_len: u32 = 0;
    var multiplier: u32 = 1;
    var header_len: usize = 1;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        try readFull(transport, pkt_buf.small[header_len .. header_len + 1]);
        const byte = pkt_buf.small[header_len];
        header_len += 1;
        remaining_len += @as(u32, byte & 0x7F) * multiplier;
        if ((byte & 0x80) == 0) break;
        multiplier *= 128;
    }

    const total = header_len + remaining_len;

    // Acquire buffer of the right size
    const buf = try pkt_buf.acquire(total);

    // Copy header bytes we already read (if we switched to heap)
    if (total > pkt_buf.small.len) {
        @memcpy(buf[0..header_len], pkt_buf.small[0..header_len]);
    }

    // Read remaining payload
    if (remaining_len > 0) {
        try readFull(transport, buf[header_len..total]);
    }

    return total;
}

// ============================================================================
// Tests
// ============================================================================

test "variable int encode/decode roundtrip" {
    var buf: [4]u8 = undefined;

    const values = [_]u32{ 0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455 };
    for (values) |v| {
        const written = try encodeVariableInt(&buf, v);
        const result = try decodeVariableInt(buf[0..written]);
        try std.testing.expectEqual(v, result.value);
        try std.testing.expectEqual(written, result.len);
    }
}

test "variable int size" {
    try std.testing.expectEqual(@as(usize, 1), variableIntSize(0));
    try std.testing.expectEqual(@as(usize, 1), variableIntSize(127));
    try std.testing.expectEqual(@as(usize, 2), variableIntSize(128));
    try std.testing.expectEqual(@as(usize, 2), variableIntSize(16383));
    try std.testing.expectEqual(@as(usize, 3), variableIntSize(16384));
    try std.testing.expectEqual(@as(usize, 4), variableIntSize(2097152));
}

test "u16 encode/decode" {
    var buf: [2]u8 = undefined;
    _ = try encodeU16(&buf, 0x1234);
    try std.testing.expectEqual(@as(u16, 0x1234), try decodeU16(&buf));
}

test "u32 encode/decode" {
    var buf: [4]u8 = undefined;
    _ = try encodeU32(&buf, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), try decodeU32(&buf));
}

test "string encode/decode" {
    var buf: [256]u8 = undefined;
    const written = try encodeString(&buf, "hello");
    const result = try decodeString(buf[0..written]);
    try std.testing.expectEqualStrings("hello", result.str);
    try std.testing.expectEqual(@as(usize, 7), result.len);
}

test "empty string encode/decode" {
    var buf: [256]u8 = undefined;
    const written = try encodeString(&buf, "");
    const result = try decodeString(buf[0..written]);
    try std.testing.expectEqualStrings("", result.str);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "fixed header encode/decode" {
    var buf: [5]u8 = undefined;
    const written = try encodeFixedHeader(&buf, .publish, 0x03, 256);
    const hdr = try decodeFixedHeader(buf[0..written]);
    try std.testing.expectEqual(PacketType.publish, hdr.packet_type);
    try std.testing.expectEqual(@as(u4, 0x03), hdr.flags);
    try std.testing.expectEqual(@as(u32, 256), hdr.remaining_len);
}

test "PacketType name" {
    try std.testing.expectEqualStrings("CONNECT", PacketType.connect.name());
    try std.testing.expectEqualStrings("PUBLISH", PacketType.publish.name());
}

test "ReasonCode isError" {
    try std.testing.expect(!ReasonCode.success.isError());
    try std.testing.expect(ReasonCode.not_authorized.isError());
    try std.testing.expect(ReasonCode.malformed_packet.isError());
}
