//! MQTT 3.1.1 (v4) Packet Encoding/Decoding
//!
//! Full codec for all MQTT 3.1.1 packet types.
//! Both client-side and server-side (broker) encode/decode.

const pkt = @import("packet.zig");

// Re-exports
pub const Error = pkt.Error;
pub const PacketType = pkt.PacketType;
pub const QoS = pkt.QoS;
pub const ConnectReturnCode = pkt.ConnectReturnCode;
pub const FixedHeader = pkt.FixedHeader;

const encodeFixedHeader = pkt.encodeFixedHeader;
const decodeFixedHeader = pkt.decodeFixedHeader;
const encodeString = pkt.encodeString;
const decodeString = pkt.decodeString;
const encodeBinary = pkt.encodeBinary;
const decodeBinary = pkt.decodeBinary;
const encodeU16 = pkt.encodeU16;
const decodeU16 = pkt.decodeU16;
const variableIntSize = pkt.variableIntSize;
const copyBytes = pkt.copyBytes;

// ============================================================================
// Decoded Packets
// ============================================================================

pub const Connect = struct {
    client_id: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    clean_session: bool = true,
    keep_alive: u16 = 60,
    will_topic: ?[]const u8 = null,
    will_message: ?[]const u8 = null,
    will_qos: QoS = .at_most_once,
    will_retain: bool = false,
};

pub const ConnAck = struct {
    session_present: bool,
    return_code: ConnectReturnCode,
};

pub const Publish = struct {
    topic: []const u8,
    payload: []const u8,
    retain: bool,
    qos: QoS,
    dup: bool,
    packet_id: u16, // 0 if QoS 0
};

pub const Subscribe = struct {
    packet_id: u16,
    /// Topic filters. Each entry: { filter_str, qos_byte }
    /// Stored as offsets into the original buffer.
    topics: []const []const u8,
    topic_count: usize,
    // Internal storage for up to max_topics
    topic_storage: [max_topics][]const u8,
};

pub const SubAck = struct {
    packet_id: u16,
    return_codes: []const u8,
    return_code_count: usize,
    code_storage: [max_topics]u8,
};

pub const Unsubscribe = struct {
    packet_id: u16,
    topics: []const []const u8,
    topic_count: usize,
    topic_storage: [max_topics][]const u8,
};

pub const UnsubAck = struct {
    packet_id: u16,
};

pub const max_topics = 32;

pub const DecodedPacket = union(PacketType) {
    reserved: void,
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: u16, // packet_id
    pubrec: u16,
    pubrel: u16,
    pubcomp: u16,
    subscribe: Subscribe,
    suback: SubAck,
    unsubscribe: Unsubscribe,
    unsuback: UnsubAck,
    pingreq: void,
    pingresp: void,
    disconnect: void,
    auth: void,
};

// ============================================================================
// Encode: CONNECT
// ============================================================================

pub fn encodeConnect(buf: []u8, config: *const pkt.ConnectConfig) Error!usize {
    // Calculate sizes
    var var_header_size: usize = 0;
    var_header_size += 2 + pkt.protocol_name.len; // Protocol name
    var_header_size += 1; // Protocol level
    var_header_size += 1; // Connect flags
    var_header_size += 2; // Keep alive

    var payload_size: usize = 0;
    payload_size += 2 + config.client_id.len; // Client ID

    if (config.will_topic) |topic| {
        payload_size += 2 + topic.len;
        if (config.will_payload) |payload| {
            payload_size += 2 + payload.len;
        } else {
            payload_size += 2;
        }
    }
    if (config.username) |u| payload_size += 2 + u.len;
    if (config.password) |p| payload_size += 2 + p.len;

    const remaining_len: u32 = @truncate(var_header_size + payload_size);
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + var_header_size + payload_size) return Error.BufferTooSmall;

    // Encode
    var offset = try encodeFixedHeader(buf, .connect, 0, remaining_len);
    offset += try encodeString(buf[offset..], pkt.protocol_name);

    buf[offset] = pkt.protocol_version_v4;
    offset += 1;

    // Connect flags
    var flags: u8 = 0;
    if (config.clean_start) flags |= 0x02;
    if (config.will_topic != null) {
        flags |= 0x04;
        flags |= @as(u8, @intFromEnum(config.will_qos)) << 3;
        if (config.will_retain) flags |= 0x20;
    }
    if (config.password != null) flags |= 0x40;
    if (config.username != null) flags |= 0x80;
    buf[offset] = flags;
    offset += 1;

    offset += try encodeU16(buf[offset..], config.keep_alive);

    // Payload
    offset += try encodeString(buf[offset..], config.client_id);

    if (config.will_topic) |topic| {
        offset += try encodeString(buf[offset..], topic);
        if (config.will_payload) |payload| {
            offset += try encodeBinary(buf[offset..], payload);
        } else {
            offset += try encodeU16(buf[offset..], 0);
        }
    }
    if (config.username) |u| offset += try encodeString(buf[offset..], u);
    if (config.password) |p| offset += try encodeBinary(buf[offset..], p);

    return offset;
}

// ============================================================================
// Encode: CONNACK
// ============================================================================

pub fn encodeConnAck(buf: []u8, session_present: bool, return_code: ConnectReturnCode) Error!usize {
    if (buf.len < 4) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .connack, 0, 2);
    buf[offset] = if (session_present) 0x01 else 0x00;
    offset += 1;
    buf[offset] = @intFromEnum(return_code);
    offset += 1;
    return offset;
}

// ============================================================================
// Encode: PUBLISH
// ============================================================================

pub fn encodePublish(buf: []u8, opts: *const pkt.PublishOptions) Error!usize {
    var var_header_size: usize = 0;
    var_header_size += 2 + opts.topic.len; // Topic
    if (@intFromEnum(opts.qos) > 0) var_header_size += 2; // Packet ID

    const remaining_len: u32 = @truncate(var_header_size + opts.payload.len);

    var flags: u4 = 0;
    if (opts.dup) flags |= 0x08;
    flags |= @as(u4, @intFromEnum(opts.qos)) << 1;
    if (opts.retain) flags |= 0x01;

    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .publish, flags, remaining_len);
    offset += try encodeString(buf[offset..], opts.topic);

    if (@intFromEnum(opts.qos) > 0) {
        offset += try encodeU16(buf[offset..], opts.packet_id);
    }

    copyBytes(buf[offset..], opts.payload);
    offset += opts.payload.len;

    return offset;
}

// ============================================================================
// Encode: SUBSCRIBE
// ============================================================================

pub fn encodeSubscribe(buf: []u8, packet_id: u16, topics: []const []const u8) Error!usize {
    var payload_size: usize = 0;
    for (topics) |topic| {
        payload_size += 2 + topic.len + 1; // String + QoS byte
    }

    const remaining_len: u32 = @truncate(2 + payload_size); // Packet ID + topics
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .subscribe, 0x02, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);

    for (topics) |topic| {
        offset += try encodeString(buf[offset..], topic);
        buf[offset] = 0x00; // QoS 0
        offset += 1;
    }

    return offset;
}

// ============================================================================
// Encode: SUBACK
// ============================================================================

pub fn encodeSubAck(buf: []u8, packet_id: u16, return_codes: []const u8) Error!usize {
    const remaining_len: u32 = @truncate(2 + return_codes.len);
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .suback, 0, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);

    for (return_codes) |code| {
        buf[offset] = code;
        offset += 1;
    }

    return offset;
}

// ============================================================================
// Encode: UNSUBSCRIBE
// ============================================================================

pub fn encodeUnsubscribe(buf: []u8, packet_id: u16, topics: []const []const u8) Error!usize {
    var payload_size: usize = 0;
    for (topics) |topic| {
        payload_size += 2 + topic.len;
    }

    const remaining_len: u32 = @truncate(2 + payload_size);
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .unsubscribe, 0x02, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);

    for (topics) |topic| {
        offset += try encodeString(buf[offset..], topic);
    }

    return offset;
}

// ============================================================================
// Encode: UNSUBACK
// ============================================================================

pub fn encodeUnsubAck(buf: []u8, packet_id: u16) Error!usize {
    if (buf.len < 4) return Error.BufferTooSmall;
    var offset = try encodeFixedHeader(buf, .unsuback, 0, 2);
    offset += try encodeU16(buf[offset..], packet_id);
    return offset;
}

// ============================================================================
// Encode: PINGREQ / PINGRESP / DISCONNECT
// ============================================================================

pub fn encodePingReq(buf: []u8) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = @as(u8, @intFromEnum(PacketType.pingreq)) << 4;
    buf[1] = 0;
    return 2;
}

pub fn encodePingResp(buf: []u8) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = @as(u8, @intFromEnum(PacketType.pingresp)) << 4;
    buf[1] = 0;
    return 2;
}

pub fn encodeDisconnect(buf: []u8) Error!usize {
    if (buf.len < 2) return Error.BufferTooSmall;
    buf[0] = @as(u8, @intFromEnum(PacketType.disconnect)) << 4;
    buf[1] = 0;
    return 2;
}

// ============================================================================
// Decode: Generic
// ============================================================================

/// Decode any v4 packet from buffer.
/// Returns the decoded packet and total bytes consumed.
pub fn decodePacket(buf: []const u8) Error!struct { packet: DecodedPacket, len: usize } {
    const header = try decodeFixedHeader(buf);
    const total_len = header.totalLen();

    if (buf.len < total_len) return Error.MalformedPacket;

    const payload = buf[header.header_len..total_len];

    const decoded: DecodedPacket = switch (header.packet_type) {
        .connect => .{ .connect = try decodeConnect(payload) },
        .connack => .{ .connack = try decodeConnAck(payload) },
        .publish => .{ .publish = try decodePublish(payload, header.flags, header.remaining_len) },
        .subscribe => .{ .subscribe = try decodeSubscribe(payload, header.remaining_len) },
        .suback => .{ .suback = try decodeSubAck(payload, header.remaining_len) },
        .unsubscribe => .{ .unsubscribe = try decodeUnsubscribe(payload, header.remaining_len) },
        .unsuback => .{ .unsuback = try decodeUnsubAck(payload) },
        .pingreq => .{ .pingreq = {} },
        .pingresp => .{ .pingresp = {} },
        .disconnect => .{ .disconnect = {} },
        else => return Error.UnknownPacketType,
    };

    return .{ .packet = decoded, .len = total_len };
}

// ============================================================================
// Decode: CONNECT
// ============================================================================

fn decodeConnect(buf: []const u8) Error!Connect {
    var offset: usize = 0;

    // Protocol name
    const name_result = try decodeString(buf[offset..]);
    offset += name_result.len;

    // Protocol level
    if (offset >= buf.len) return Error.MalformedPacket;
    if (buf[offset] != pkt.protocol_version_v4) return Error.UnsupportedProtocolVersion;
    offset += 1;

    // Connect flags
    if (offset >= buf.len) return Error.MalformedPacket;
    const flags = buf[offset];
    offset += 1;

    const clean_session = flags & 0x02 != 0;
    const will_flag = flags & 0x04 != 0;
    const will_qos: QoS = @enumFromInt((flags >> 3) & 0x03);
    const will_retain = flags & 0x20 != 0;
    const password_flag = flags & 0x40 != 0;
    const username_flag = flags & 0x80 != 0;

    // Keep alive
    const keep_alive = try decodeU16(buf[offset..]);
    offset += 2;

    // Client ID
    const client_id_result = try decodeString(buf[offset..]);
    offset += client_id_result.len;

    var result = Connect{
        .client_id = client_id_result.str,
        .clean_session = clean_session,
        .keep_alive = keep_alive,
    };

    // Will
    if (will_flag) {
        const will_topic_result = try decodeString(buf[offset..]);
        offset += will_topic_result.len;
        result.will_topic = will_topic_result.str;

        const will_msg_result = try decodeBinary(buf[offset..]);
        offset += will_msg_result.len;
        result.will_message = will_msg_result.data;
        result.will_qos = will_qos;
        result.will_retain = will_retain;
    }

    // Username
    if (username_flag) {
        const username_result = try decodeString(buf[offset..]);
        offset += username_result.len;
        result.username = username_result.str;
    }

    // Password
    if (password_flag) {
        const password_result = try decodeBinary(buf[offset..]);
        offset += password_result.len;
        result.password = password_result.data;
    }

    return result;
}

// ============================================================================
// Decode: CONNACK
// ============================================================================

fn decodeConnAck(buf: []const u8) Error!ConnAck {
    if (buf.len < 2) return Error.MalformedPacket;
    return .{
        .session_present = buf[0] & 0x01 != 0,
        .return_code = @enumFromInt(buf[1]),
    };
}

// ============================================================================
// Decode: PUBLISH
// ============================================================================

fn decodePublish(buf: []const u8, flags: u4, remaining_len: u32) Error!Publish {
    const dup = flags & 0x08 != 0;
    const qos: QoS = @enumFromInt((flags >> 1) & 0x03);
    const retain = flags & 0x01 != 0;

    var offset: usize = 0;

    const topic_result = try decodeString(buf[offset..]);
    offset += topic_result.len;

    var packet_id: u16 = 0;
    if (@intFromEnum(qos) > 0) {
        packet_id = try decodeU16(buf[offset..]);
        offset += 2;
    }

    const payload_len = remaining_len - @as(u32, @truncate(offset));
    const payload = buf[offset .. offset + payload_len];

    return .{
        .topic = topic_result.str,
        .payload = payload,
        .retain = retain,
        .qos = qos,
        .dup = dup,
        .packet_id = packet_id,
    };
}

// ============================================================================
// Decode: SUBSCRIBE
// ============================================================================

fn decodeSubscribe(buf: []const u8, remaining_len: u32) Error!Subscribe {
    var offset: usize = 0;

    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    var result = Subscribe{
        .packet_id = packet_id,
        .topics = &.{},
        .topic_count = 0,
        .topic_storage = undefined,
    };

    while (offset < remaining_len) {
        if (result.topic_count >= max_topics) break;

        const topic_result = try decodeString(buf[offset..]);
        offset += topic_result.len;

        // QoS byte (we read but ignore for QoS 0 implementation)
        if (offset >= buf.len) return Error.MalformedPacket;
        offset += 1;

        result.topic_storage[result.topic_count] = topic_result.str;
        result.topic_count += 1;
    }

    result.topics = result.topic_storage[0..result.topic_count];
    return result;
}

// ============================================================================
// Decode: SUBACK
// ============================================================================

fn decodeSubAck(buf: []const u8, remaining_len: u32) Error!SubAck {
    if (buf.len < 2) return Error.MalformedPacket;

    var offset: usize = 0;
    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    var result = SubAck{
        .packet_id = packet_id,
        .return_codes = &.{},
        .return_code_count = 0,
        .code_storage = undefined,
    };

    const codes_len = remaining_len - 2;
    var i: usize = 0;
    while (i < codes_len and i < max_topics) : (i += 1) {
        if (offset + i >= buf.len) break;
        result.code_storage[i] = buf[offset + i];
        result.return_code_count += 1;
    }

    result.return_codes = result.code_storage[0..result.return_code_count];
    return result;
}

// ============================================================================
// Decode: UNSUBSCRIBE
// ============================================================================

fn decodeUnsubscribe(buf: []const u8, remaining_len: u32) Error!Unsubscribe {
    var offset: usize = 0;

    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    var result = Unsubscribe{
        .packet_id = packet_id,
        .topics = &.{},
        .topic_count = 0,
        .topic_storage = undefined,
    };

    while (offset < remaining_len) {
        if (result.topic_count >= max_topics) break;

        const topic_result = try decodeString(buf[offset..]);
        offset += topic_result.len;

        result.topic_storage[result.topic_count] = topic_result.str;
        result.topic_count += 1;
    }

    result.topics = result.topic_storage[0..result.topic_count];
    return result;
}

// ============================================================================
// Decode: UNSUBACK
// ============================================================================

fn decodeUnsubAck(buf: []const u8) Error!UnsubAck {
    if (buf.len < 2) return Error.MalformedPacket;
    return .{ .packet_id = try decodeU16(buf) };
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

test "v4 CONNECT encode/decode roundtrip" {
    var buf: [256]u8 = undefined;

    const config = pkt.ConnectConfig{
        .client_id = "test-client",
        .username = "user",
        .password = "pass",
        .clean_start = true,
        .keep_alive = 60,
        .protocol_version = .v4,
    };

    const n = try encodeConnect(&buf, &config);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .connect => |conn| {
            try testing.expectEqualSlices(u8, "test-client", conn.client_id);
            try testing.expectEqualSlices(u8, "user", conn.username.?);
            try testing.expectEqualSlices(u8, "pass", conn.password.?);
            try testing.expectEqual(true, conn.clean_session);
            try testing.expectEqual(@as(u16, 60), conn.keep_alive);
        },
        else => return error.TestExpectedEqual,
    }
}

test "v4 CONNACK encode/decode roundtrip" {
    var buf: [16]u8 = undefined;

    const n = try encodeConnAck(&buf, false, .accepted);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .connack => |ack| {
            try testing.expectEqual(false, ack.session_present);
            try testing.expectEqual(ConnectReturnCode.accepted, ack.return_code);
        },
        else => return error.TestExpectedEqual,
    }
}

test "v4 PUBLISH encode/decode roundtrip" {
    var buf: [256]u8 = undefined;

    const opts = pkt.PublishOptions{
        .topic = "test/topic",
        .payload = "hello world",
        .retain = true,
    };

    const n = try encodePublish(&buf, &opts);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .publish => |pub_pkt| {
            try testing.expectEqualSlices(u8, "test/topic", pub_pkt.topic);
            try testing.expectEqualSlices(u8, "hello world", pub_pkt.payload);
            try testing.expectEqual(true, pub_pkt.retain);
            try testing.expectEqual(QoS.at_most_once, pub_pkt.qos);
        },
        else => return error.TestExpectedEqual,
    }
}

test "v4 SUBSCRIBE/SUBACK roundtrip" {
    var buf: [256]u8 = undefined;

    // SUBSCRIBE
    {
        const topics = [_][]const u8{ "sensor/+/data", "device/#" };
        const n = try encodeSubscribe(&buf, 42, &topics);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .subscribe => |sub| {
                try testing.expectEqual(@as(u16, 42), sub.packet_id);
                try testing.expectEqual(@as(usize, 2), sub.topic_count);
                try testing.expectEqualSlices(u8, "sensor/+/data", sub.topics[0]);
                try testing.expectEqualSlices(u8, "device/#", sub.topics[1]);
            },
            else => return error.TestExpectedEqual,
        }
    }

    // SUBACK
    {
        const codes = [_]u8{ 0x00, 0x00 };
        const n = try encodeSubAck(&buf, 42, &codes);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .suback => |ack| {
                try testing.expectEqual(@as(u16, 42), ack.packet_id);
                try testing.expectEqual(@as(usize, 2), ack.return_code_count);
                try testing.expectEqual(@as(u8, 0x00), ack.return_codes[0]);
            },
            else => return error.TestExpectedEqual,
        }
    }
}

test "v4 UNSUBSCRIBE/UNSUBACK roundtrip" {
    var buf: [256]u8 = undefined;

    // UNSUBSCRIBE
    {
        const topics = [_][]const u8{"test/topic"};
        const n = try encodeUnsubscribe(&buf, 7, &topics);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .unsubscribe => |unsub| {
                try testing.expectEqual(@as(u16, 7), unsub.packet_id);
                try testing.expectEqual(@as(usize, 1), unsub.topic_count);
                try testing.expectEqualSlices(u8, "test/topic", unsub.topics[0]);
            },
            else => return error.TestExpectedEqual,
        }
    }

    // UNSUBACK
    {
        const n = try encodeUnsubAck(&buf, 7);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .unsuback => |ack| {
                try testing.expectEqual(@as(u16, 7), ack.packet_id);
            },
            else => return error.TestExpectedEqual,
        }
    }
}

test "v4 PINGREQ/PINGRESP roundtrip" {
    var buf: [4]u8 = undefined;

    {
        const n = try encodePingReq(&buf);
        const result = try decodePacket(buf[0..n]);
        try testing.expectEqual(PacketType.pingreq, @as(PacketType, result.packet));
    }

    {
        const n = try encodePingResp(&buf);
        const result = try decodePacket(buf[0..n]);
        try testing.expectEqual(PacketType.pingresp, @as(PacketType, result.packet));
    }
}

test "v4 DISCONNECT roundtrip" {
    var buf: [4]u8 = undefined;
    const n = try encodeDisconnect(&buf);
    const result = try decodePacket(buf[0..n]);
    try testing.expectEqual(PacketType.disconnect, @as(PacketType, result.packet));
}

test "v4 CONNECT with will message" {
    var buf: [512]u8 = undefined;

    const config = pkt.ConnectConfig{
        .client_id = "will-client",
        .clean_start = true,
        .keep_alive = 30,
        .will_topic = "device/offline",
        .will_payload = "goodbye",
        .will_qos = .at_most_once,
        .will_retain = true,
        .protocol_version = .v4,
    };

    const n = try encodeConnect(&buf, &config);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .connect => |conn| {
            try testing.expectEqualSlices(u8, "will-client", conn.client_id);
            try testing.expectEqualSlices(u8, "device/offline", conn.will_topic.?);
            try testing.expectEqualSlices(u8, "goodbye", conn.will_message.?);
            try testing.expectEqual(true, conn.will_retain);
        },
        else => return error.TestExpectedEqual,
    }
}
