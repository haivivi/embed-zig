//! MQTT Packet Primitives
//!
//! Shared encoding/decoding primitives for MQTT 3.1.1 and 5.0.
//! Zero std dependency — all operations are manual byte manipulation.

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
};

// ============================================================================
// Constants
// ============================================================================

pub const protocol_name = "MQTT";
pub const protocol_version_v4: u8 = 4; // MQTT 3.1.1
pub const protocol_version_v5: u8 = 5; // MQTT 5.0

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
// Reason Codes (MQTT 5.0, also used as v4 connect return codes)
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

/// MQTT 3.1.1 Connect Return Codes (subset of ReasonCode values)
pub const ConnectReturnCode = enum(u8) {
    accepted = 0x00,
    bad_protocol = 0x01,
    id_rejected = 0x02,
    server_unavailable = 0x03,
    bad_credentials = 0x04,
    not_authorized = 0x05,
    _,

    pub fn isError(self: ConnectReturnCode) bool {
        return @intFromEnum(self) != 0x00;
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
// Variable-Length Integer Encoding
// ============================================================================

/// Encode a variable-length integer (MQTT spec).
/// Returns the number of bytes written.
pub fn encodeVariableInt(buf: []u8, value: u32) Error!usize {
    var v = value;
    var i: usize = 0;

    while (true) {
        if (i >= buf.len) return Error.BufferTooSmall;

        var byte_val: u8 = @truncate(v & 0x7F);
        v >>= 7;

        if (v > 0) {
            byte_val |= 0x80;
        }

        buf[i] = byte_val;
        i += 1;

        if (v == 0) break;
    }

    return i;
}

/// Decode a variable-length integer.
/// Returns the value and number of bytes consumed.
pub fn decodeVariableInt(buf: []const u8) Error!struct { value: u32, len: usize } {
    var value: u32 = 0;
    var multiplier: u32 = 1;
    var i: usize = 0;

    while (i < 4) {
        if (i >= buf.len) return Error.MalformedVariableInt;

        const byte_val = buf[i];
        value += @as(u32, byte_val & 0x7F) * multiplier;

        i += 1;

        if ((byte_val & 0x80) == 0) {
            return .{ .value = value, .len = i };
        }

        multiplier *= 128;
    }

    return Error.MalformedVariableInt;
}

/// Get the encoded size of a variable-length integer.
pub fn variableIntSize(value: u32) usize {
    if (value < 128) return 1;
    if (value < 16384) return 2;
    if (value < 2097152) return 3;
    return 4;
}

// ============================================================================
// Integer Encoding
// ============================================================================

/// Encode a 16-bit unsigned integer (big-endian).
pub fn encodeU16(buf: []u8, value: u16) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = @truncate(value >> 8);
    buf[1] = @truncate(value & 0xFF);
    return 2;
}

/// Decode a 16-bit unsigned integer (big-endian).
pub fn decodeU16(buf: []const u8) Error!u16 {
    if (buf.len < 2) return Error.MalformedPacket;
    return (@as(u16, buf[0]) << 8) | @as(u16, buf[1]);
}

/// Encode a 32-bit unsigned integer (big-endian).
pub fn encodeU32(buf: []u8, value: u32) Error!usize {
    if (buf.len < 4) return Error.BufferTooSmall;
    buf[0] = @truncate(value >> 24);
    buf[1] = @truncate((value >> 16) & 0xFF);
    buf[2] = @truncate((value >> 8) & 0xFF);
    buf[3] = @truncate(value & 0xFF);
    return 4;
}

/// Decode a 32-bit unsigned integer (big-endian).
pub fn decodeU32(buf: []const u8) Error!u32 {
    if (buf.len < 4) return Error.MalformedPacket;
    return (@as(u32, buf[0]) << 24) |
        (@as(u32, buf[1]) << 16) |
        (@as(u32, buf[2]) << 8) |
        @as(u32, buf[3]);
}

// ============================================================================
// String / Binary Encoding
// ============================================================================

/// Encode a UTF-8 string (2-byte length prefix + data).
pub fn encodeString(buf: []u8, str: []const u8) Error!usize {
    if (str.len > 65535) return Error.MalformedString;
    if (buf.len < 2 + str.len) return Error.BufferTooSmall;

    _ = try encodeU16(buf[0..2], @truncate(str.len));

    for (str, 0..) |c, i| {
        buf[2 + i] = c;
    }

    return 2 + str.len;
}

/// Decode a UTF-8 string.
/// Returns the string slice (into buf) and total bytes consumed.
pub fn decodeString(buf: []const u8) Error!struct { str: []const u8, len: usize } {
    if (buf.len < 2) return Error.MalformedString;

    const str_len = try decodeU16(buf[0..2]);
    const total_len = 2 + @as(usize, str_len);

    if (buf.len < total_len) return Error.MalformedString;

    return .{
        .str = buf[2..total_len],
        .len = total_len,
    };
}

/// Encode binary data (2-byte length prefix + data). Same format as string.
pub fn encodeBinary(buf: []u8, data: []const u8) Error!usize {
    return encodeString(buf, data);
}

/// Decode binary data.
pub fn decodeBinary(buf: []const u8) Error!struct { data: []const u8, len: usize } {
    const result = try decodeString(buf);
    return .{ .data = result.str, .len = result.len };
}

// ============================================================================
// Fixed Header
// ============================================================================

/// Encode the fixed header (packet type + flags + remaining length).
pub fn encodeFixedHeader(buf: []u8, pkt_type: PacketType, flags: u4, remaining_len: u32) Error!usize {
    if (buf.len < 1) return Error.BufferTooSmall;

    buf[0] = (@as(u8, @intFromEnum(pkt_type)) << 4) | @as(u8, flags);

    const var_len = try encodeVariableInt(buf[1..], remaining_len);

    return 1 + var_len;
}

/// Decode the fixed header.
pub fn decodeFixedHeader(buf: []const u8) Error!FixedHeader {
    if (buf.len < 2) return Error.MalformedPacket;

    const first_byte = buf[0];
    const pkt_type_raw = first_byte >> 4;
    const flags: u4 = @truncate(first_byte & 0x0F);

    const pkt_type: PacketType = @enumFromInt(pkt_type_raw);

    const var_result = try decodeVariableInt(buf[1..]);

    return .{
        .packet_type = pkt_type,
        .flags = flags,
        .remaining_len = var_result.value,
        .header_len = 1 + var_result.len,
    };
}

pub const FixedHeader = struct {
    packet_type: PacketType,
    flags: u4,
    remaining_len: u32,
    header_len: usize,

    /// Total packet length = header + remaining
    pub fn totalLen(self: FixedHeader) usize {
        return self.header_len + self.remaining_len;
    }
};

// ============================================================================
// Connect Config (shared between v4 and v5)
// ============================================================================

pub const ConnectConfig = struct {
    client_id: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    clean_start: bool = true,
    keep_alive: u16 = 60,

    // Will message (optional)
    will_topic: ?[]const u8 = null,
    will_payload: ?[]const u8 = null,
    will_qos: QoS = .at_most_once,
    will_retain: bool = false,

    // Protocol version
    protocol_version: ProtocolVersion = .v5,
};

/// Publish options (shared between v4 and v5)
pub const PublishOptions = struct {
    topic: []const u8,
    payload: []const u8,
    retain: bool = false,
    qos: QoS = .at_most_once,
    dup: bool = false,
    packet_id: u16 = 0, // only for QoS > 0
};

// ============================================================================
// Message
// ============================================================================

/// A received MQTT message (slices into caller's buffer — zero copy)
pub const Message = struct {
    topic: []const u8,
    payload: []const u8,
    retain: bool,
};

// ============================================================================
// Handler
// ============================================================================

/// Message handler — ctx + function pointer pattern (like Go's Handler interface)
pub const Handler = struct {
    ctx: ?*anyopaque,
    handleFn: *const fn (ctx: ?*anyopaque, msg: *const Message) void,

    pub fn handle(self: Handler, msg: *const Message) void {
        self.handleFn(self.ctx, msg);
    }
};

/// Adapter: wrap a simple function as a Handler (like Go's HandlerFunc)
pub fn handlerFn(comptime f: *const fn (*const Message) void) Handler {
    return .{
        .ctx = null,
        .handleFn = struct {
            fn wrapper(_: ?*anyopaque, msg: *const Message) void {
                f(msg);
            }
        }.wrapper,
    };
}

// ============================================================================
// Utility
// ============================================================================

/// Copy bytes (avoids @memcpy for freestanding compatibility)
pub fn copyBytes(dst: []u8, src: []const u8) void {
    for (src, 0..) |b, i| {
        dst[i] = b;
    }
}

/// Detect protocol version from the first bytes of a CONNECT packet.
/// Needs at least 10 bytes to determine version.
/// Returns null if not enough data or not a CONNECT packet.
pub fn detectProtocolVersion(peek: []const u8) ?ProtocolVersion {
    if (peek.len < 2) return null;

    // Must be a CONNECT packet (0x10)
    if (peek[0] & 0xF0 != 0x10) return null;

    // Parse remaining length to find header_len
    var header_len: usize = 1;
    var i: usize = 1;
    while (i < peek.len and i < 5) : (i += 1) {
        header_len += 1;
        if (peek[i] & 0x80 == 0) break;
    }

    // Protocol level offset: header_len + 2 (name length) + 4 ("MQTT")
    const proto_level_offset = header_len + 2 + 4;
    if (peek.len <= proto_level_offset) return null;

    return switch (peek[proto_level_offset]) {
        4 => .v4,
        5 => .v5,
        else => null,
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = struct {
    fn expectEqual(expected: anytype, actual: anytype) !void {
        if (expected != actual) return error.TestExpectedEqual;
    }

    fn expectEqualSlices(comptime T: type, expected: []const T, actual: []const T) !void {
        if (expected.len != actual.len) return error.TestExpectedEqual;
        for (expected, actual) |e, a| {
            if (e != a) return error.TestExpectedEqual;
        }
    }
};

test "varint encode/decode roundtrip" {
    var buf: [4]u8 = undefined;

    // Test various values
    const test_values = [_]u32{ 0, 1, 127, 128, 16383, 16384, 2097151, 2097152, 268435455 };
    for (test_values) |v| {
        const n = try encodeVariableInt(&buf, v);
        const result = try decodeVariableInt(buf[0..n]);
        try testing.expectEqual(v, result.value);
        try testing.expectEqual(n, result.len);
    }
}

test "varint sizes" {
    try testing.expectEqual(@as(usize, 1), variableIntSize(0));
    try testing.expectEqual(@as(usize, 1), variableIntSize(127));
    try testing.expectEqual(@as(usize, 2), variableIntSize(128));
    try testing.expectEqual(@as(usize, 2), variableIntSize(16383));
    try testing.expectEqual(@as(usize, 3), variableIntSize(16384));
    try testing.expectEqual(@as(usize, 4), variableIntSize(2097152));
}

test "u16 encode/decode roundtrip" {
    var buf: [2]u8 = undefined;
    const values = [_]u16{ 0, 1, 255, 256, 65535 };
    for (values) |v| {
        _ = try encodeU16(&buf, v);
        const decoded = try decodeU16(&buf);
        try testing.expectEqual(v, decoded);
    }
}

test "u32 encode/decode roundtrip" {
    var buf: [4]u8 = undefined;
    const values = [_]u32{ 0, 1, 255, 65535, 0xDEADBEEF };
    for (values) |v| {
        _ = try encodeU32(&buf, v);
        const decoded = try decodeU32(&buf);
        try testing.expectEqual(v, decoded);
    }
}

test "string encode/decode roundtrip" {
    var buf: [256]u8 = undefined;

    // Empty string
    {
        const n = try encodeString(&buf, "");
        try testing.expectEqual(@as(usize, 2), n);
        const result = try decodeString(buf[0..n]);
        try testing.expectEqual(@as(usize, 0), result.str.len);
    }

    // Normal string
    {
        const s = "hello/world";
        const n = try encodeString(&buf, s);
        try testing.expectEqual(2 + s.len, n);
        const result = try decodeString(buf[0..n]);
        try testing.expectEqualSlices(u8, s, result.str);
    }
}

test "fixed header encode/decode roundtrip" {
    var buf: [5]u8 = undefined;

    // CONNECT with small remaining
    {
        const n = try encodeFixedHeader(&buf, .connect, 0, 10);
        const hdr = try decodeFixedHeader(buf[0..n]);
        try testing.expectEqual(PacketType.connect, hdr.packet_type);
        try testing.expectEqual(@as(u4, 0), hdr.flags);
        try testing.expectEqual(@as(u32, 10), hdr.remaining_len);
    }

    // PUBLISH with retain flag and large remaining
    {
        const n = try encodeFixedHeader(&buf, .publish, 0x01, 300);
        const hdr = try decodeFixedHeader(buf[0..n]);
        try testing.expectEqual(PacketType.publish, hdr.packet_type);
        try testing.expectEqual(@as(u4, 0x01), hdr.flags);
        try testing.expectEqual(@as(u32, 300), hdr.remaining_len);
    }

    // SUBSCRIBE with fixed flags 0x02
    {
        const n = try encodeFixedHeader(&buf, .subscribe, 0x02, 0);
        const hdr = try decodeFixedHeader(buf[0..n]);
        try testing.expectEqual(PacketType.subscribe, hdr.packet_type);
        try testing.expectEqual(@as(u4, 0x02), hdr.flags);
        try testing.expectEqual(@as(u32, 0), hdr.remaining_len);
    }

    // PINGREQ with zero remaining
    {
        const n = try encodeFixedHeader(&buf, .pingreq, 0, 0);
        const hdr = try decodeFixedHeader(buf[0..n]);
        try testing.expectEqual(PacketType.pingreq, hdr.packet_type);
        try testing.expectEqual(@as(u32, 0), hdr.remaining_len);
    }
}

test "detect protocol version" {
    // MQTT 3.1.1 CONNECT packet (minimal)
    // Fixed header: 0x10, remaining_len
    // Variable header: protocol name "MQTT" (00 04 4D 51 54 54), protocol level 4
    const v4_connect = [_]u8{
        0x10, 0x0E, // Fixed header: CONNECT, remaining = 14
        0x00, 0x04, 'M', 'Q', 'T', 'T', // Protocol name
        0x04, // Protocol level = 4 (v3.1.1)
        0x02, // Connect flags
        0x00, 0x3C, // Keep alive = 60
        0x00, 0x00, // Client ID (empty)
    };
    try testing.expectEqual(ProtocolVersion.v4, detectProtocolVersion(&v4_connect).?);

    // MQTT 5.0 CONNECT packet
    var v5_connect = v4_connect;
    v5_connect[8] = 0x05; // Protocol level = 5
    try testing.expectEqual(ProtocolVersion.v5, detectProtocolVersion(&v5_connect).?);

    // Not a CONNECT packet
    const not_connect = [_]u8{ 0x30, 0x00 }; // PUBLISH
    try testing.expectEqual(@as(?ProtocolVersion, null), detectProtocolVersion(&not_connect));

    // Too short
    try testing.expectEqual(@as(?ProtocolVersion, null), detectProtocolVersion(&[_]u8{0x10}));
}

test "buffer too small errors" {
    var tiny: [0]u8 = undefined;

    // varint
    {
        const result = encodeVariableInt(&tiny, 1);
        try testing.expectEqual(true, result == Error.BufferTooSmall);
    }

    // u16
    {
        const result = encodeU16(&tiny, 1);
        try testing.expectEqual(true, result == Error.BufferTooSmall);
    }

    // string
    {
        const result = encodeString(&tiny, "hello");
        try testing.expectEqual(true, result == Error.BufferTooSmall);
    }
}

test "reason code is error" {
    try testing.expectEqual(false, ReasonCode.success.isError());
    try testing.expectEqual(false, ReasonCode.granted_qos_1.isError());
    try testing.expectEqual(true, ReasonCode.unspecified_error.isError());
    try testing.expectEqual(true, ReasonCode.not_authorized.isError());
}
