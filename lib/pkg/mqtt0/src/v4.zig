//! MQTT 3.1.1 (v4) Packet Encoding/Decoding
//!
//! Encodes and decodes all MQTT 3.1.1 packet types into caller-provided buffers.

const std = @import("std");
const pkt = @import("packet.zig");

const Error = pkt.Error;
const PacketType = pkt.PacketType;
const ConnectReturnCode = pkt.ConnectReturnCode;
const QoS = pkt.QoS;

const protocol_level: u8 = 4;

// ============================================================================
// Packet Structures
// ============================================================================

pub const Connect = struct {
    client_id: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    clean_session: bool = true,
    keep_alive: u16 = 60,
    will_topic: []const u8 = "",
    will_message: []const u8 = "",
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
    retain: bool = false,
    dup: bool = false,
    qos: QoS = .at_most_once,
    packet_id: u16 = 0,
};

pub const Subscribe = struct {
    packet_id: u16,
    topics: []const []const u8,
};

pub const SubAck = struct {
    packet_id: u16,
    return_codes: []const u8,
};

pub const Unsubscribe = struct {
    packet_id: u16,
    topics: []const []const u8,
};

pub const UnsubAck = struct {
    packet_id: u16,
};

// ============================================================================
// Decoded Packet (tagged union)
// ============================================================================

pub const Packet = union(PacketType) {
    reserved: void,
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: void,
    pubrec: void,
    pubrel: void,
    pubcomp: void,
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
// Encoding
// ============================================================================

/// Encode CONNECT packet. Returns total bytes written.
pub fn encodeConnect(buf: []u8, c: *const Connect) Error!usize {
    // Build variable header + payload into a temp region
    var offset: usize = 5; // max fixed header size, we'll backfill

    // Variable header
    // Protocol name
    offset += try pkt.encodeString(buf[offset..], pkt.protocol_name);
    // Protocol level
    if (offset >= buf.len) return Error.BufferTooSmall;
    buf[offset] = protocol_level;
    offset += 1;
    // Connect flags
    var flags: u8 = 0;
    if (c.clean_session) flags |= 0x02;
    if (c.will_topic.len > 0) {
        flags |= 0x04;
        flags |= @as(u8, @intFromEnum(c.will_qos)) << 3;
        if (c.will_retain) flags |= 0x20;
    }
    if (c.password.len > 0) flags |= 0x40;
    if (c.username.len > 0) flags |= 0x80;
    if (offset >= buf.len) return Error.BufferTooSmall;
    buf[offset] = flags;
    offset += 1;
    // Keep alive
    offset += try pkt.encodeU16(buf[offset..], c.keep_alive);

    // Payload
    offset += try pkt.encodeString(buf[offset..], c.client_id);
    if (c.will_topic.len > 0) {
        offset += try pkt.encodeString(buf[offset..], c.will_topic);
        offset += try pkt.encodeBinary(buf[offset..], c.will_message);
    }
    if (c.username.len > 0) {
        offset += try pkt.encodeString(buf[offset..], c.username);
    }
    if (c.password.len > 0) {
        offset += try pkt.encodeBinary(buf[offset..], c.password);
    }

    // Now backfill the fixed header
    const payload_len = offset - 5;
    return backfillHeader(buf, .connect, 0, payload_len, offset);
}

/// Encode CONNACK packet.
pub fn encodeConnAck(buf: []u8, ca: *const ConnAck) Error!usize {
    if (buf.len < 4) return Error.BufferTooSmall;
    var payload: [2]u8 = undefined;
    payload[0] = if (ca.session_present) 0x01 else 0x00;
    payload[1] = @intFromEnum(ca.return_code);
    return pkt.buildPacket(buf, .connack, 0, &payload);
}

/// Encode PUBLISH packet.
pub fn encodePublish(buf: []u8, p: *const Publish) Error!usize {
    var offset: usize = 5;

    // Topic
    offset += try pkt.encodeString(buf[offset..], p.topic);
    // Packet ID (only for QoS > 0)
    if (p.qos != .at_most_once) {
        offset += try pkt.encodeU16(buf[offset..], p.packet_id);
    }
    // Payload
    if (offset + p.payload.len > buf.len) return Error.BufferTooSmall;
    @memcpy(buf[offset .. offset + p.payload.len], p.payload);
    offset += p.payload.len;

    var flags: u4 = 0;
    if (p.dup) flags |= 0x08;
    flags |= @as(u4, @intFromEnum(p.qos)) << 1;
    if (p.retain) flags |= 0x01;

    const payload_len = offset - 5;
    return backfillHeader(buf, .publish, flags, payload_len, offset);
}

/// Encode SUBSCRIBE packet.
pub fn encodeSubscribe(buf: []u8, s: *const Subscribe) Error!usize {
    var offset: usize = 5;

    // Packet ID
    offset += try pkt.encodeU16(buf[offset..], s.packet_id);
    // Topic filters
    for (s.topics) |topic| {
        offset += try pkt.encodeString(buf[offset..], topic);
        if (offset >= buf.len) return Error.BufferTooSmall;
        buf[offset] = 0; // QoS 0
        offset += 1;
    }

    const payload_len = offset - 5;
    return backfillHeader(buf, .subscribe, 0x02, payload_len, offset);
}

/// Encode SUBACK packet.
pub fn encodeSubAck(buf: []u8, sa: *const SubAck) Error!usize {
    var offset: usize = 5;
    offset += try pkt.encodeU16(buf[offset..], sa.packet_id);
    if (offset + sa.return_codes.len > buf.len) return Error.BufferTooSmall;
    @memcpy(buf[offset .. offset + sa.return_codes.len], sa.return_codes);
    offset += sa.return_codes.len;
    const payload_len = offset - 5;
    return backfillHeader(buf, .suback, 0, payload_len, offset);
}

/// Encode UNSUBSCRIBE packet.
pub fn encodeUnsubscribe(buf: []u8, u: *const Unsubscribe) Error!usize {
    var offset: usize = 5;
    offset += try pkt.encodeU16(buf[offset..], u.packet_id);
    for (u.topics) |topic| {
        offset += try pkt.encodeString(buf[offset..], topic);
    }
    const payload_len = offset - 5;
    return backfillHeader(buf, .unsubscribe, 0x02, payload_len, offset);
}

/// Encode UNSUBACK packet.
pub fn encodeUnsubAck(buf: []u8, packet_id: u16) Error!usize {
    var payload: [2]u8 = undefined;
    _ = try pkt.encodeU16(&payload, packet_id);
    return pkt.buildPacket(buf, .unsuback, 0, &payload);
}

/// Encode PINGREQ.
pub fn encodePingReq(buf: []u8) Error!usize {
    return pkt.buildPacket(buf, .pingreq, 0, &.{});
}

/// Encode PINGRESP.
pub fn encodePingResp(buf: []u8) Error!usize {
    return pkt.buildPacket(buf, .pingresp, 0, &.{});
}

/// Encode DISCONNECT.
pub fn encodeDisconnect(buf: []u8) Error!usize {
    return pkt.buildPacket(buf, .disconnect, 0, &.{});
}

// ============================================================================
// Decoding
// ============================================================================

/// Decode a complete v4 packet from buffer.
pub fn decodePacket(buf: []const u8) Error!struct { packet: Packet, len: usize } {
    const hdr = try pkt.decodeFixedHeader(buf);
    const total = hdr.header_len + hdr.remaining_len;
    if (buf.len < total) return Error.MalformedPacket;
    const payload = buf[hdr.header_len..total];

    const packet: Packet = switch (hdr.packet_type) {
        .connect => .{ .connect = try decodeConnect(payload) },
        .connack => .{ .connack = try decodeConnAck(payload) },
        .publish => .{ .publish = try decodePublish(payload, hdr.flags, hdr.remaining_len) },
        .subscribe => .{ .subscribe = try decodeSubscribePacket(payload, hdr.remaining_len) },
        .suback => .{ .suback = try decodeSubAckPacket(payload, hdr.remaining_len) },
        .unsubscribe => .{ .unsubscribe = try decodeUnsubscribePacket(payload, hdr.remaining_len) },
        .unsuback => .{ .unsuback = try decodeUnsubAckPacket(payload) },
        .pingreq => .{ .pingreq = {} },
        .pingresp => .{ .pingresp = {} },
        .disconnect => .{ .disconnect = {} },
        else => return Error.UnknownPacketType,
    };

    return .{ .packet = packet, .len = total };
}

fn decodeConnect(buf: []const u8) Error!Connect {
    var off: usize = 0;

    // Protocol name
    const name_r = try pkt.decodeString(buf[off..]);
    if (!std.mem.eql(u8, name_r.str, pkt.protocol_name)) return Error.ProtocolError;
    off += name_r.len;

    // Protocol level
    if (off >= buf.len) return Error.MalformedPacket;
    if (buf[off] != protocol_level) return Error.UnsupportedProtocolVersion;
    off += 1;

    // Connect flags
    if (off >= buf.len) return Error.MalformedPacket;
    const flags = buf[off];
    off += 1;
    const clean_session = flags & 0x02 != 0;
    const will_flag = flags & 0x04 != 0;
    const will_qos: QoS = @enumFromInt(@as(u2, @truncate((flags >> 3) & 0x03)));
    const will_retain = flags & 0x20 != 0;
    const password_flag = flags & 0x40 != 0;
    const username_flag = flags & 0x80 != 0;

    // Keep alive
    const ka = try pkt.decodeU16(buf[off..]);
    off += 2;

    // Client ID
    const cid_r = try pkt.decodeString(buf[off..]);
    off += cid_r.len;

    var c = Connect{
        .client_id = cid_r.str,
        .clean_session = clean_session,
        .keep_alive = ka,
        .will_qos = will_qos,
        .will_retain = will_retain,
    };

    if (will_flag) {
        const wt = try pkt.decodeString(buf[off..]);
        off += wt.len;
        c.will_topic = wt.str;
        const wm = try pkt.decodeBinary(buf[off..]);
        off += wm.len;
        c.will_message = wm.data;
    }
    if (username_flag) {
        const u = try pkt.decodeString(buf[off..]);
        off += u.len;
        c.username = u.str;
    }
    if (password_flag) {
        const p = try pkt.decodeBinary(buf[off..]);
        off += p.len;
        c.password = p.data;
    }

    return c;
}

fn decodeConnAck(buf: []const u8) Error!ConnAck {
    if (buf.len < 2) return Error.MalformedPacket;
    return .{
        .session_present = buf[0] & 0x01 != 0,
        .return_code = @enumFromInt(buf[1]),
    };
}

fn decodePublish(buf: []const u8, flags: u4, remaining_len: u32) Error!Publish {
    const dup = flags & 0x08 != 0;
    const qos: QoS = @enumFromInt(@as(u2, @truncate((flags >> 1) & 0x03)));
    const retain = flags & 0x01 != 0;

    var off: usize = 0;
    const topic_r = try pkt.decodeString(buf[off..]);
    off += topic_r.len;

    var packet_id: u16 = 0;
    if (qos != .at_most_once) {
        packet_id = try pkt.decodeU16(buf[off..]);
        off += 2;
    }

    const payload_len = remaining_len - @as(u32, @truncate(off));
    const payload = buf[off .. off + payload_len];

    return .{
        .topic = topic_r.str,
        .payload = payload,
        .retain = retain,
        .dup = dup,
        .qos = qos,
        .packet_id = packet_id,
    };
}

fn decodeSubscribePacket(buf: []const u8, remaining_len: u32) Error!Subscribe {
    _ = remaining_len;
    var off: usize = 0;
    const pid = try pkt.decodeU16(buf[off..]);
    off += 2;
    // We return a Subscribe with topics pointing into buf.
    // Caller must process before buf is reused.
    // For simplicity, we return a single-topic subscribe here.
    // Full implementation would need an allocator or bounded array.
    return .{
        .packet_id = pid,
        .topics = &.{}, // Caller should use decodeSubscribeTopics for iteration
    };
}

fn decodeSubAckPacket(buf: []const u8, remaining_len: u32) Error!SubAck {
    if (buf.len < 2) return Error.MalformedPacket;
    const pid = try pkt.decodeU16(buf[0..2]);
    const codes_len = remaining_len - 2;
    return .{
        .packet_id = pid,
        .return_codes = buf[2 .. 2 + codes_len],
    };
}

fn decodeUnsubscribePacket(buf: []const u8, remaining_len: u32) Error!Unsubscribe {
    _ = remaining_len;
    const pid = try pkt.decodeU16(buf[0..2]);
    return .{
        .packet_id = pid,
        .topics = &.{},
    };
}

fn decodeUnsubAckPacket(buf: []const u8) Error!UnsubAck {
    if (buf.len < 2) return Error.MalformedPacket;
    return .{ .packet_id = try pkt.decodeU16(buf[0..2]) };
}

// ============================================================================
// Subscribe Topic Iterator (for decoding)
// ============================================================================

pub const SubscribeTopicIterator = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(payload: []const u8, skip_packet_id: bool) SubscribeTopicIterator {
        return .{ .buf = payload, .pos = if (skip_packet_id) 2 else 0 };
    }

    pub fn next(self: *SubscribeTopicIterator) Error!?struct { topic: []const u8, qos: u8 } {
        if (self.pos >= self.buf.len) return null;
        const r = try pkt.decodeString(self.buf[self.pos..]);
        self.pos += r.len;
        if (self.pos >= self.buf.len) return Error.MalformedPacket;
        const qos = self.buf[self.pos];
        self.pos += 1;
        return .{ .topic = r.str, .qos = qos };
    }
};

/// Iterator for unsubscribe topics
pub const UnsubscribeTopicIterator = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(payload: []const u8, skip_packet_id: bool) UnsubscribeTopicIterator {
        return .{ .buf = payload, .pos = if (skip_packet_id) 2 else 0 };
    }

    pub fn next(self: *UnsubscribeTopicIterator) Error!?[]const u8 {
        if (self.pos >= self.buf.len) return null;
        const r = try pkt.decodeString(self.buf[self.pos..]);
        self.pos += r.len;
        return r.str;
    }
};

// ============================================================================
// Internal Helpers
// ============================================================================

/// Backfill fixed header at the start of buf, shifting payload as needed.
/// `payload_start` is always 5 (max header), `payload_len` is actual payload size.
fn backfillHeader(buf: []u8, packet_type: PacketType, flags: u4, payload_len: usize, total_written: usize) Error!usize {
    const remaining: u32 = @truncate(payload_len);
    const header_size = 1 + pkt.variableIntSize(remaining);
    const payload_start: usize = 5; // We always start writing payload at offset 5

    // Shift payload to be right after the actual header
    if (header_size < payload_start) {
        const src = buf[payload_start..total_written];
        std.mem.copyForwards(u8, buf[header_size..], src);
    }

    // Write header
    _ = try pkt.encodeFixedHeader(buf, packet_type, flags, remaining);

    return header_size + payload_len;
}

// ============================================================================
// Tests
// ============================================================================

test "CONNECT encode/decode roundtrip" {
    var buf: [256]u8 = undefined;

    const connect = Connect{
        .client_id = "test-client",
        .username = "user",
        .password = "pass",
        .clean_session = true,
        .keep_alive = 60,
    };
    const written = try encodeConnect(&buf, &connect);
    const result = try decodePacket(buf[0..written]);

    switch (result.packet) {
        .connect => |c| {
            try std.testing.expectEqualStrings("test-client", c.client_id);
            try std.testing.expectEqualStrings("user", c.username);
            try std.testing.expectEqualStrings("pass", c.password);
            try std.testing.expect(c.clean_session);
            try std.testing.expectEqual(@as(u16, 60), c.keep_alive);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "CONNACK encode/decode roundtrip" {
    var buf: [16]u8 = undefined;
    const written = try encodeConnAck(&buf, &.{
        .session_present = false,
        .return_code = .accepted,
    });
    const result = try decodePacket(buf[0..written]);
    switch (result.packet) {
        .connack => |ca| {
            try std.testing.expect(!ca.session_present);
            try std.testing.expectEqual(ConnectReturnCode.accepted, ca.return_code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "PUBLISH encode/decode roundtrip" {
    var buf: [256]u8 = undefined;
    const written = try encodePublish(&buf, &.{
        .topic = "test/topic",
        .payload = "hello world",
        .retain = true,
    });
    const result = try decodePacket(buf[0..written]);
    switch (result.packet) {
        .publish => |p| {
            try std.testing.expectEqualStrings("test/topic", p.topic);
            try std.testing.expectEqualStrings("hello world", p.payload);
            try std.testing.expect(p.retain);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "PINGREQ encode/decode" {
    var buf: [4]u8 = undefined;
    const written = try encodePingReq(&buf);
    try std.testing.expectEqual(@as(usize, 2), written);
    const result = try decodePacket(buf[0..written]);
    try std.testing.expect(result.packet == .pingreq);
}

test "DISCONNECT encode/decode" {
    var buf: [4]u8 = undefined;
    const written = try encodeDisconnect(&buf);
    try std.testing.expectEqual(@as(usize, 2), written);
    const result = try decodePacket(buf[0..written]);
    try std.testing.expect(result.packet == .disconnect);
}
