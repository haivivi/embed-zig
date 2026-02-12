//! MQTT 5.0 Packet Encoding/Decoding
//!
//! Extends v4 with Properties support and new packet fields.

const std = @import("std");
const pkt = @import("packet.zig");

const Error = pkt.Error;
const PacketType = pkt.PacketType;
const ReasonCode = pkt.ReasonCode;
const QoS = pkt.QoS;

const protocol_level: u8 = 5;

// ============================================================================
// Property Identifiers
// ============================================================================

pub const PropertyId = enum(u8) {
    payload_format = 0x01,
    message_expiry = 0x02,
    content_type = 0x03,
    response_topic = 0x08,
    correlation_data = 0x09,
    subscription_id = 0x0B,
    session_expiry = 0x11,
    assigned_client_id = 0x12,
    server_keep_alive = 0x13,
    auth_method = 0x15,
    auth_data = 0x16,
    request_problem_info = 0x17,
    will_delay_interval = 0x18,
    request_response_info = 0x19,
    response_info = 0x1A,
    server_reference = 0x1C,
    reason_string = 0x1F,
    receive_maximum = 0x21,
    topic_alias_maximum = 0x22,
    topic_alias = 0x23,
    maximum_qos = 0x24,
    retain_available = 0x25,
    user_property = 0x26,
    maximum_packet_size = 0x27,
    wildcard_sub_available = 0x28,
    sub_id_available = 0x29,
    shared_sub_available = 0x2A,
    _,
};

// ============================================================================
// Properties
// ============================================================================

pub const Properties = struct {
    session_expiry: ?u32 = null,
    receive_maximum: ?u16 = null,
    maximum_packet_size: ?u32 = null,
    topic_alias_maximum: ?u16 = null,
    server_keep_alive: ?u16 = null,
    topic_alias: ?u16 = null,
    message_expiry: ?u32 = null,
    payload_format: ?u8 = null,
    content_type: ?[]const u8 = null,
    response_topic: ?[]const u8 = null,
    correlation_data: ?[]const u8 = null,
    reason_string: ?[]const u8 = null,
    assigned_client_id: ?[]const u8 = null,
    maximum_qos: ?u8 = null,
    retain_available: ?bool = null,
    wildcard_sub_available: ?bool = null,
    sub_id_available: ?bool = null,
    shared_sub_available: ?bool = null,
    server_reference: ?[]const u8 = null,
    auth_method: ?[]const u8 = null,
    auth_data: ?[]const u8 = null,
};

/// Encode properties into buffer. Returns bytes written.
pub fn encodeProperties(buf: []u8, props: *const Properties) Error!usize {
    // First pass: calculate property bytes length
    var prop_len: usize = 0;
    if (props.session_expiry != null) prop_len += 1 + 4;
    if (props.receive_maximum != null) prop_len += 1 + 2;
    if (props.maximum_packet_size != null) prop_len += 1 + 4;
    if (props.topic_alias_maximum != null) prop_len += 1 + 2;
    if (props.server_keep_alive != null) prop_len += 1 + 2;
    if (props.topic_alias != null) prop_len += 1 + 2;
    if (props.message_expiry != null) prop_len += 1 + 4;
    if (props.payload_format != null) prop_len += 1 + 1;
    if (props.content_type) |s| prop_len += 1 + 2 + s.len;
    if (props.response_topic) |s| prop_len += 1 + 2 + s.len;
    if (props.correlation_data) |d| prop_len += 1 + 2 + d.len;
    if (props.reason_string) |s| prop_len += 1 + 2 + s.len;
    if (props.assigned_client_id) |s| prop_len += 1 + 2 + s.len;
    if (props.maximum_qos != null) prop_len += 1 + 1;
    if (props.retain_available != null) prop_len += 1 + 1;
    if (props.wildcard_sub_available != null) prop_len += 1 + 1;
    if (props.sub_id_available != null) prop_len += 1 + 1;
    if (props.shared_sub_available != null) prop_len += 1 + 1;
    if (props.server_reference) |s| prop_len += 1 + 2 + s.len;
    if (props.auth_method) |s| prop_len += 1 + 2 + s.len;
    if (props.auth_data) |d| prop_len += 1 + 2 + d.len;

    // Property length (variable int)
    var off = try pkt.encodeVariableInt(buf, @truncate(prop_len));

    // Encode each property
    if (props.session_expiry) |v| {
        buf[off] = @intFromEnum(PropertyId.session_expiry);
        off += 1;
        off += try pkt.encodeU32(buf[off..], v);
    }
    if (props.receive_maximum) |v| {
        buf[off] = @intFromEnum(PropertyId.receive_maximum);
        off += 1;
        off += try pkt.encodeU16(buf[off..], v);
    }
    if (props.maximum_packet_size) |v| {
        buf[off] = @intFromEnum(PropertyId.maximum_packet_size);
        off += 1;
        off += try pkt.encodeU32(buf[off..], v);
    }
    if (props.topic_alias_maximum) |v| {
        buf[off] = @intFromEnum(PropertyId.topic_alias_maximum);
        off += 1;
        off += try pkt.encodeU16(buf[off..], v);
    }
    if (props.server_keep_alive) |v| {
        buf[off] = @intFromEnum(PropertyId.server_keep_alive);
        off += 1;
        off += try pkt.encodeU16(buf[off..], v);
    }
    if (props.topic_alias) |v| {
        buf[off] = @intFromEnum(PropertyId.topic_alias);
        off += 1;
        off += try pkt.encodeU16(buf[off..], v);
    }
    if (props.message_expiry) |v| {
        buf[off] = @intFromEnum(PropertyId.message_expiry);
        off += 1;
        off += try pkt.encodeU32(buf[off..], v);
    }
    if (props.payload_format) |v| {
        buf[off] = @intFromEnum(PropertyId.payload_format);
        off += 1;
        buf[off] = v;
        off += 1;
    }
    if (props.content_type) |s| {
        buf[off] = @intFromEnum(PropertyId.content_type);
        off += 1;
        off += try pkt.encodeString(buf[off..], s);
    }
    if (props.response_topic) |s| {
        buf[off] = @intFromEnum(PropertyId.response_topic);
        off += 1;
        off += try pkt.encodeString(buf[off..], s);
    }
    if (props.correlation_data) |d| {
        buf[off] = @intFromEnum(PropertyId.correlation_data);
        off += 1;
        off += try pkt.encodeBinary(buf[off..], d);
    }
    if (props.reason_string) |s| {
        buf[off] = @intFromEnum(PropertyId.reason_string);
        off += 1;
        off += try pkt.encodeString(buf[off..], s);
    }
    if (props.assigned_client_id) |s| {
        buf[off] = @intFromEnum(PropertyId.assigned_client_id);
        off += 1;
        off += try pkt.encodeString(buf[off..], s);
    }
    if (props.maximum_qos) |v| {
        buf[off] = @intFromEnum(PropertyId.maximum_qos);
        off += 1;
        buf[off] = v;
        off += 1;
    }
    if (props.retain_available) |v| {
        buf[off] = @intFromEnum(PropertyId.retain_available);
        off += 1;
        buf[off] = if (v) 1 else 0;
        off += 1;
    }
    if (props.wildcard_sub_available) |v| {
        buf[off] = @intFromEnum(PropertyId.wildcard_sub_available);
        off += 1;
        buf[off] = if (v) 1 else 0;
        off += 1;
    }
    if (props.sub_id_available) |v| {
        buf[off] = @intFromEnum(PropertyId.sub_id_available);
        off += 1;
        buf[off] = if (v) 1 else 0;
        off += 1;
    }
    if (props.shared_sub_available) |v| {
        buf[off] = @intFromEnum(PropertyId.shared_sub_available);
        off += 1;
        buf[off] = if (v) 1 else 0;
        off += 1;
    }
    if (props.server_reference) |s| {
        buf[off] = @intFromEnum(PropertyId.server_reference);
        off += 1;
        off += try pkt.encodeString(buf[off..], s);
    }
    if (props.auth_method) |s| {
        buf[off] = @intFromEnum(PropertyId.auth_method);
        off += 1;
        off += try pkt.encodeString(buf[off..], s);
    }
    if (props.auth_data) |d| {
        buf[off] = @intFromEnum(PropertyId.auth_data);
        off += 1;
        off += try pkt.encodeBinary(buf[off..], d);
    }

    return off;
}

/// Decode properties from buffer. Returns properties and bytes consumed.
pub fn decodeProperties(buf: []const u8) Error!struct { props: Properties, len: usize } {
    const vr = try pkt.decodeVariableInt(buf);
    const prop_len = vr.value;
    var off: usize = vr.len;
    const end = off + prop_len;

    if (end > buf.len) return Error.MalformedPacket;

    var props = Properties{};

    while (off < end) {
        const prop_id = buf[off];
        off += 1;

        switch (prop_id) {
            @intFromEnum(PropertyId.session_expiry) => {
                props.session_expiry = try pkt.decodeU32(buf[off..]);
                off += 4;
            },
            @intFromEnum(PropertyId.receive_maximum) => {
                props.receive_maximum = try pkt.decodeU16(buf[off..]);
                off += 2;
            },
            @intFromEnum(PropertyId.maximum_packet_size) => {
                props.maximum_packet_size = try pkt.decodeU32(buf[off..]);
                off += 4;
            },
            @intFromEnum(PropertyId.topic_alias_maximum) => {
                props.topic_alias_maximum = try pkt.decodeU16(buf[off..]);
                off += 2;
            },
            @intFromEnum(PropertyId.server_keep_alive) => {
                props.server_keep_alive = try pkt.decodeU16(buf[off..]);
                off += 2;
            },
            @intFromEnum(PropertyId.topic_alias) => {
                props.topic_alias = try pkt.decodeU16(buf[off..]);
                off += 2;
            },
            @intFromEnum(PropertyId.message_expiry) => {
                props.message_expiry = try pkt.decodeU32(buf[off..]);
                off += 4;
            },
            @intFromEnum(PropertyId.payload_format) => {
                if (off >= buf.len) return Error.MalformedPacket;
                props.payload_format = buf[off];
                off += 1;
            },
            @intFromEnum(PropertyId.content_type) => {
                const r = try pkt.decodeString(buf[off..]);
                props.content_type = r.str;
                off += r.len;
            },
            @intFromEnum(PropertyId.response_topic) => {
                const r = try pkt.decodeString(buf[off..]);
                props.response_topic = r.str;
                off += r.len;
            },
            @intFromEnum(PropertyId.correlation_data) => {
                const r = try pkt.decodeBinary(buf[off..]);
                props.correlation_data = r.data;
                off += r.len;
            },
            @intFromEnum(PropertyId.reason_string) => {
                const r = try pkt.decodeString(buf[off..]);
                props.reason_string = r.str;
                off += r.len;
            },
            @intFromEnum(PropertyId.assigned_client_id) => {
                const r = try pkt.decodeString(buf[off..]);
                props.assigned_client_id = r.str;
                off += r.len;
            },
            @intFromEnum(PropertyId.maximum_qos) => {
                if (off >= buf.len) return Error.MalformedPacket;
                props.maximum_qos = buf[off];
                off += 1;
            },
            @intFromEnum(PropertyId.retain_available) => {
                if (off >= buf.len) return Error.MalformedPacket;
                props.retain_available = buf[off] != 0;
                off += 1;
            },
            @intFromEnum(PropertyId.wildcard_sub_available) => {
                if (off >= buf.len) return Error.MalformedPacket;
                props.wildcard_sub_available = buf[off] != 0;
                off += 1;
            },
            @intFromEnum(PropertyId.sub_id_available) => {
                if (off >= buf.len) return Error.MalformedPacket;
                props.sub_id_available = buf[off] != 0;
                off += 1;
            },
            @intFromEnum(PropertyId.shared_sub_available) => {
                if (off >= buf.len) return Error.MalformedPacket;
                props.shared_sub_available = buf[off] != 0;
                off += 1;
            },
            @intFromEnum(PropertyId.server_reference) => {
                const r = try pkt.decodeString(buf[off..]);
                props.server_reference = r.str;
                off += r.len;
            },
            @intFromEnum(PropertyId.auth_method) => {
                const r = try pkt.decodeString(buf[off..]);
                props.auth_method = r.str;
                off += r.len;
            },
            @intFromEnum(PropertyId.auth_data) => {
                const r = try pkt.decodeBinary(buf[off..]);
                props.auth_data = r.data;
                off += r.len;
            },
            @intFromEnum(PropertyId.user_property) => {
                // Skip user properties (key + value strings)
                const kr = try pkt.decodeString(buf[off..]);
                off += kr.len;
                const vr2 = try pkt.decodeString(buf[off..]);
                off += vr2.len;
            },
            @intFromEnum(PropertyId.subscription_id) => {
                const svr = try pkt.decodeVariableInt(buf[off..]);
                off += svr.len;
            },
            @intFromEnum(PropertyId.will_delay_interval) => {
                off += 4; // skip
            },
            @intFromEnum(PropertyId.request_problem_info),
            @intFromEnum(PropertyId.request_response_info),
            => {
                off += 1; // skip single byte
            },
            @intFromEnum(PropertyId.response_info) => {
                const r = try pkt.decodeString(buf[off..]);
                off += r.len;
            },
            else => return Error.ProtocolError, // Unknown property
        }
    }

    return .{ .props = props, .len = end };
}

// ============================================================================
// Packet Structures
// ============================================================================

pub const Connect = struct {
    client_id: []const u8 = "",
    username: []const u8 = "",
    password: []const u8 = "",
    clean_start: bool = true,
    keep_alive: u16 = 60,
    properties: Properties = .{},
    will_topic: []const u8 = "",
    will_message: []const u8 = "",
    will_qos: QoS = .at_most_once,
    will_retain: bool = false,
};

pub const ConnAck = struct {
    session_present: bool = false,
    reason_code: ReasonCode = .success,
    properties: Properties = .{},
};

pub const Publish = struct {
    topic: []const u8,
    payload: []const u8,
    retain: bool = false,
    dup: bool = false,
    qos: QoS = .at_most_once,
    packet_id: u16 = 0,
    properties: Properties = .{},
};

pub const SubAck = struct {
    packet_id: u16,
    reason_codes: []const ReasonCode,
    properties: Properties = .{},
};

pub const Disconnect = struct {
    reason_code: ReasonCode = .success,
    properties: Properties = .{},
};

// ============================================================================
// Decoded Packet
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
    subscribe: struct { packet_id: u16, properties: Properties },
    suback: SubAck,
    unsubscribe: struct { packet_id: u16, properties: Properties },
    unsuback: struct { packet_id: u16, reason_codes: []const ReasonCode, properties: Properties },
    pingreq: void,
    pingresp: void,
    disconnect: Disconnect,
    auth: void,
};

// ============================================================================
// Encoding
// ============================================================================

pub fn encodeConnect(buf: []u8, c: *const Connect) Error!usize {
    var off: usize = 5;

    // Variable header
    off += try pkt.encodeString(buf[off..], pkt.protocol_name);
    buf[off] = protocol_level;
    off += 1;

    var flags: u8 = 0;
    if (c.clean_start) flags |= 0x02;
    if (c.will_topic.len > 0) {
        flags |= 0x04;
        flags |= @as(u8, @intFromEnum(c.will_qos)) << 3;
        if (c.will_retain) flags |= 0x20;
    }
    if (c.password.len > 0) flags |= 0x40;
    if (c.username.len > 0) flags |= 0x80;
    buf[off] = flags;
    off += 1;

    off += try pkt.encodeU16(buf[off..], c.keep_alive);

    // Properties
    off += try encodeProperties(buf[off..], &c.properties);

    // Payload
    off += try pkt.encodeString(buf[off..], c.client_id);
    if (c.will_topic.len > 0) {
        off += try encodeProperties(buf[off..], &Properties{}); // will props (empty)
        off += try pkt.encodeString(buf[off..], c.will_topic);
        off += try pkt.encodeBinary(buf[off..], c.will_message);
    }
    if (c.username.len > 0) off += try pkt.encodeString(buf[off..], c.username);
    if (c.password.len > 0) off += try pkt.encodeBinary(buf[off..], c.password);

    const payload_len = off - 5;
    return backfillHeader(buf, .connect, 0, payload_len, off);
}

pub fn encodeConnAck(buf: []u8, ca: *const ConnAck) Error!usize {
    var off: usize = 5;
    buf[off] = if (ca.session_present) 0x01 else 0x00;
    off += 1;
    buf[off] = @intFromEnum(ca.reason_code);
    off += 1;
    off += try encodeProperties(buf[off..], &ca.properties);
    const payload_len = off - 5;
    return backfillHeader(buf, .connack, 0, payload_len, off);
}

pub fn encodePublish(buf: []u8, p: *const Publish) Error!usize {
    var off: usize = 5;
    off += try pkt.encodeString(buf[off..], p.topic);
    if (p.qos != .at_most_once) off += try pkt.encodeU16(buf[off..], p.packet_id);
    off += try encodeProperties(buf[off..], &p.properties);
    if (off + p.payload.len > buf.len) return Error.BufferTooSmall;
    @memcpy(buf[off .. off + p.payload.len], p.payload);
    off += p.payload.len;

    var flags: u4 = 0;
    if (p.dup) flags |= 0x08;
    flags |= @as(u4, @intFromEnum(p.qos)) << 1;
    if (p.retain) flags |= 0x01;

    const payload_len = off - 5;
    return backfillHeader(buf, .publish, flags, payload_len, off);
}

pub fn encodeSubscribe(buf: []u8, packet_id: u16, topics: []const []const u8, props: *const Properties) Error!usize {
    var off: usize = 5;
    off += try pkt.encodeU16(buf[off..], packet_id);
    off += try encodeProperties(buf[off..], props);
    for (topics) |topic| {
        off += try pkt.encodeString(buf[off..], topic);
        buf[off] = 0; // subscription options: QoS 0
        off += 1;
    }
    const payload_len = off - 5;
    return backfillHeader(buf, .subscribe, 0x02, payload_len, off);
}

pub fn encodeSubAck(buf: []u8, sa: *const SubAck) Error!usize {
    var off: usize = 5;
    off += try pkt.encodeU16(buf[off..], sa.packet_id);
    off += try encodeProperties(buf[off..], &sa.properties);
    for (sa.reason_codes) |rc| {
        buf[off] = @intFromEnum(rc);
        off += 1;
    }
    const payload_len = off - 5;
    return backfillHeader(buf, .suback, 0, payload_len, off);
}

pub fn encodeUnsubscribe(buf: []u8, packet_id: u16, topics: []const []const u8, props: *const Properties) Error!usize {
    var off: usize = 5;
    off += try pkt.encodeU16(buf[off..], packet_id);
    off += try encodeProperties(buf[off..], props);
    for (topics) |topic| {
        off += try pkt.encodeString(buf[off..], topic);
    }
    const payload_len = off - 5;
    return backfillHeader(buf, .unsubscribe, 0x02, payload_len, off);
}

pub fn encodeDisconnect(buf: []u8, d: *const Disconnect) Error!usize {
    if (d.reason_code == .success) {
        return pkt.buildPacket(buf, .disconnect, 0, &.{});
    }
    var off: usize = 5;
    buf[off] = @intFromEnum(d.reason_code);
    off += 1;
    off += try encodeProperties(buf[off..], &d.properties);
    const payload_len = off - 5;
    return backfillHeader(buf, .disconnect, 0, payload_len, off);
}

pub fn encodePingReq(buf: []u8) Error!usize {
    return pkt.buildPacket(buf, .pingreq, 0, &.{});
}

pub fn encodePingResp(buf: []u8) Error!usize {
    return pkt.buildPacket(buf, .pingresp, 0, &.{});
}

// ============================================================================
// Decoding
// ============================================================================

pub fn decodePacket(buf: []const u8) Error!struct { packet: Packet, len: usize } {
    const hdr = try pkt.decodeFixedHeader(buf);
    const total = hdr.header_len + hdr.remaining_len;
    if (buf.len < total) return Error.MalformedPacket;
    const payload = buf[hdr.header_len..total];

    const packet: Packet = switch (hdr.packet_type) {
        .connect => .{ .connect = try decodeConnect(payload) },
        .connack => .{ .connack = try decodeConnAck(payload) },
        .publish => .{ .publish = try decodePublish(payload, hdr.flags, hdr.remaining_len) },
        .suback => .{ .suback = try decodeSubAck(payload, hdr.remaining_len) },
        .pingreq => .{ .pingreq = {} },
        .pingresp => .{ .pingresp = {} },
        .disconnect => .{ .disconnect = try decodeDisconnectPkt(payload, hdr.remaining_len) },
        .subscribe => blk: {
            var off: usize = 0;
            const pid = try pkt.decodeU16(payload[off..]);
            off += 2;
            const pr = try decodeProperties(payload[off..]);
            break :blk .{ .subscribe = .{ .packet_id = pid, .properties = pr.props } };
        },
        .unsubscribe => blk: {
            var off: usize = 0;
            const pid = try pkt.decodeU16(payload[off..]);
            off += 2;
            const pr = try decodeProperties(payload[off..]);
            break :blk .{ .unsubscribe = .{ .packet_id = pid, .properties = pr.props } };
        },
        else => return Error.UnknownPacketType,
    };

    return .{ .packet = packet, .len = total };
}

fn decodeConnect(buf: []const u8) Error!Connect {
    var off: usize = 0;
    const name_r = try pkt.decodeString(buf[off..]);
    if (!std.mem.eql(u8, name_r.str, pkt.protocol_name)) return Error.ProtocolError;
    off += name_r.len;

    if (off >= buf.len) return Error.MalformedPacket;
    if (buf[off] != protocol_level) return Error.UnsupportedProtocolVersion;
    off += 1;

    if (off >= buf.len) return Error.MalformedPacket;
    const flags = buf[off];
    off += 1;
    const clean_start = flags & 0x02 != 0;
    const will_flag = flags & 0x04 != 0;
    const will_qos: QoS = @enumFromInt(@as(u2, @truncate((flags >> 3) & 0x03)));
    const will_retain = flags & 0x20 != 0;
    const password_flag = flags & 0x40 != 0;
    const username_flag = flags & 0x80 != 0;

    const ka = try pkt.decodeU16(buf[off..]);
    off += 2;

    // Properties
    const pr = try decodeProperties(buf[off..]);
    off += pr.len;

    // Client ID
    const cid = try pkt.decodeString(buf[off..]);
    off += cid.len;

    var c = Connect{
        .client_id = cid.str,
        .clean_start = clean_start,
        .keep_alive = ka,
        .properties = pr.props,
        .will_qos = will_qos,
        .will_retain = will_retain,
    };

    if (will_flag) {
        const wp = try decodeProperties(buf[off..]);
        off += wp.len;
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
    var off: usize = 0;
    const session_present = buf[off] & 0x01 != 0;
    off += 1;
    const reason_code: ReasonCode = @enumFromInt(buf[off]);
    off += 1;

    var props = Properties{};
    if (off < buf.len) {
        const pr = try decodeProperties(buf[off..]);
        props = pr.props;
    }

    return .{
        .session_present = session_present,
        .reason_code = reason_code,
        .properties = props,
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

    const pr = try decodeProperties(buf[off..]);
    off += pr.len;

    const payload_len = remaining_len - @as(u32, @truncate(off));
    return .{
        .topic = topic_r.str,
        .payload = buf[off .. off + payload_len],
        .retain = retain,
        .dup = dup,
        .qos = qos,
        .packet_id = packet_id,
        .properties = pr.props,
    };
}

fn decodeSubAck(buf: []const u8, remaining_len: u32) Error!SubAck {
    var off: usize = 0;
    const pid = try pkt.decodeU16(buf[off..]);
    off += 2;
    const pr = try decodeProperties(buf[off..]);
    off += pr.len;
    const codes_len = remaining_len - @as(u32, @truncate(off));
    // Return raw byte slice, caller casts
    const raw_codes = buf[off .. off + codes_len];
    return .{
        .packet_id = pid,
        .reason_codes = @as([*]const ReasonCode, @ptrCast(raw_codes.ptr))[0..codes_len],
        .properties = pr.props,
    };
}

fn decodeDisconnectPkt(buf: []const u8, remaining_len: u32) Error!Disconnect {
    if (remaining_len == 0) return .{};
    if (buf.len < 1) return Error.MalformedPacket;
    var off: usize = 0;
    const rc: ReasonCode = @enumFromInt(buf[off]);
    off += 1;
    var props = Properties{};
    if (remaining_len > 1 and off < buf.len) {
        const pr = try decodeProperties(buf[off..]);
        props = pr.props;
    }
    return .{ .reason_code = rc, .properties = props };
}

/// Subscribe topic iterator for v5 (includes subscription options)
pub const SubscribeTopicIterator = struct {
    buf: []const u8,
    pos: usize,

    pub fn init(payload: []const u8, packet_id_and_props_len: usize) SubscribeTopicIterator {
        return .{ .buf = payload, .pos = packet_id_and_props_len };
    }

    pub fn next(self: *SubscribeTopicIterator) Error!?struct { topic: []const u8, qos: u8, options: u8 } {
        if (self.pos >= self.buf.len) return null;
        const r = try pkt.decodeString(self.buf[self.pos..]);
        self.pos += r.len;
        if (self.pos >= self.buf.len) return Error.MalformedPacket;
        const opts = self.buf[self.pos];
        self.pos += 1;
        return .{ .topic = r.str, .qos = opts & 0x03, .options = opts };
    }
};

// ============================================================================
// Internal
// ============================================================================

fn backfillHeader(buf: []u8, packet_type: PacketType, flags: u4, payload_len: usize, total_written: usize) Error!usize {
    const remaining: u32 = @truncate(payload_len);
    const header_size = 1 + pkt.variableIntSize(remaining);
    const payload_start: usize = 5;
    if (header_size < payload_start) {
        const src = buf[payload_start..total_written];
        std.mem.copyForwards(u8, buf[header_size..], src);
    }
    _ = try pkt.encodeFixedHeader(buf, packet_type, flags, remaining);
    return header_size + payload_len;
}

// ============================================================================
// Tests
// ============================================================================

test "v5 CONNECT encode/decode roundtrip" {
    var buf: [512]u8 = undefined;
    const connect = Connect{
        .client_id = "test-v5",
        .username = "user",
        .password = "pass",
        .clean_start = true,
        .keep_alive = 30,
        .properties = .{ .session_expiry = 3600 },
    };
    const written = try encodeConnect(&buf, &connect);
    const result = try decodePacket(buf[0..written]);
    switch (result.packet) {
        .connect => |c| {
            try std.testing.expectEqualStrings("test-v5", c.client_id);
            try std.testing.expectEqualStrings("user", c.username);
            try std.testing.expectEqual(@as(u16, 30), c.keep_alive);
            try std.testing.expectEqual(@as(u32, 3600), c.properties.session_expiry.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "v5 CONNACK encode/decode roundtrip" {
    var buf: [128]u8 = undefined;
    const written = try encodeConnAck(&buf, &.{
        .reason_code = .success,
        .properties = .{ .topic_alias_maximum = 100 },
    });
    const result = try decodePacket(buf[0..written]);
    switch (result.packet) {
        .connack => |ca| {
            try std.testing.expectEqual(ReasonCode.success, ca.reason_code);
            try std.testing.expectEqual(@as(u16, 100), ca.properties.topic_alias_maximum.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "v5 PUBLISH encode/decode roundtrip" {
    var buf: [256]u8 = undefined;
    const written = try encodePublish(&buf, &.{
        .topic = "test/v5",
        .payload = "hello v5",
        .retain = true,
        .properties = .{ .message_expiry = 60 },
    });
    const result = try decodePacket(buf[0..written]);
    switch (result.packet) {
        .publish => |p| {
            try std.testing.expectEqualStrings("test/v5", p.topic);
            try std.testing.expectEqualStrings("hello v5", p.payload);
            try std.testing.expect(p.retain);
            try std.testing.expectEqual(@as(u32, 60), p.properties.message_expiry.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "v5 properties encode/decode roundtrip" {
    var buf: [256]u8 = undefined;
    const props = Properties{
        .session_expiry = 3600,
        .receive_maximum = 100,
        .topic_alias_maximum = 50,
        .content_type = "application/json",
    };
    const written = try encodeProperties(&buf, &props);
    const result = try decodeProperties(buf[0..written]);
    try std.testing.expectEqual(@as(u32, 3600), result.props.session_expiry.?);
    try std.testing.expectEqual(@as(u16, 100), result.props.receive_maximum.?);
    try std.testing.expectEqual(@as(u16, 50), result.props.topic_alias_maximum.?);
    try std.testing.expectEqualStrings("application/json", result.props.content_type.?);
}

test "v5 DISCONNECT encode/decode" {
    var buf: [32]u8 = undefined;
    // Normal disconnect (empty)
    const written = try encodeDisconnect(&buf, &.{});
    const result = try decodePacket(buf[0..written]);
    switch (result.packet) {
        .disconnect => |d| {
            try std.testing.expectEqual(ReasonCode.success, d.reason_code);
        },
        else => return error.TestUnexpectedResult,
    }
}
