//! MQTT 5.0 (v5) Packet Encoding/Decoding
//!
//! Full codec for all MQTT 5.0 packet types with complete property support.
//! Both client-side and server-side (broker) encode/decode.

const pkt = @import("packet.zig");

// Re-exports
pub const Error = pkt.Error;
pub const PacketType = pkt.PacketType;
pub const QoS = pkt.QoS;
pub const ReasonCode = pkt.ReasonCode;
pub const FixedHeader = pkt.FixedHeader;

const encodeFixedHeader = pkt.encodeFixedHeader;
const decodeFixedHeader = pkt.decodeFixedHeader;
const encodeString = pkt.encodeString;
const decodeString = pkt.decodeString;
const encodeBinary = pkt.encodeBinary;
const decodeBinary = pkt.decodeBinary;
const encodeU16 = pkt.encodeU16;
const decodeU16 = pkt.decodeU16;
const encodeU32 = pkt.encodeU32;
const decodeU32 = pkt.decodeU32;
const encodeVariableInt = pkt.encodeVariableInt;
const decodeVariableInt = pkt.decodeVariableInt;
const variableIntSize = pkt.variableIntSize;
const copyBytes = pkt.copyBytes;

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
// Properties (MQTT 5.0 — all 26 property types)
// ============================================================================

/// Max user properties per packet
pub const max_user_properties = 8;

pub const UserProperty = struct {
    key: []const u8,
    value: []const u8,
};

pub const Properties = struct {
    // Connection properties
    session_expiry: ?u32 = null,
    receive_maximum: ?u16 = null,
    maximum_qos: ?u8 = null,
    retain_available: ?bool = null,
    maximum_packet_size: ?u32 = null,
    assigned_client_id: ?[]const u8 = null,
    topic_alias_maximum: ?u16 = null,
    server_keep_alive: ?u16 = null,
    wildcard_sub_available: ?bool = null,
    sub_id_available: ?bool = null,
    shared_sub_available: ?bool = null,

    // Publish properties
    topic_alias: ?u16 = null,
    message_expiry: ?u32 = null,
    payload_format: ?u8 = null,
    content_type: ?[]const u8 = null,
    response_topic: ?[]const u8 = null,
    correlation_data: ?[]const u8 = null,
    subscription_id: ?u32 = null,

    // Will properties
    will_delay_interval: ?u32 = null,

    // Auth
    auth_method: ?[]const u8 = null,
    auth_data: ?[]const u8 = null,

    // Info
    reason_string: ?[]const u8 = null,
    response_info: ?[]const u8 = null,
    server_reference: ?[]const u8 = null,

    // Request flags
    request_problem_info: ?u8 = null,
    request_response_info: ?u8 = null,

    // User properties
    user_properties: [max_user_properties]UserProperty = undefined,
    user_property_count: usize = 0,

    /// Calculate the encoded size of properties (not including the length prefix)
    pub fn encodedSize(self: *const Properties) usize {
        var size: usize = 0;

        if (self.session_expiry != null) size += 1 + 4;
        if (self.receive_maximum != null) size += 1 + 2;
        if (self.maximum_qos != null) size += 1 + 1;
        if (self.retain_available != null) size += 1 + 1;
        if (self.maximum_packet_size != null) size += 1 + 4;
        if (self.assigned_client_id) |s| size += 1 + 2 + s.len;
        if (self.topic_alias_maximum != null) size += 1 + 2;
        if (self.server_keep_alive != null) size += 1 + 2;
        if (self.wildcard_sub_available != null) size += 1 + 1;
        if (self.sub_id_available != null) size += 1 + 1;
        if (self.shared_sub_available != null) size += 1 + 1;
        if (self.topic_alias != null) size += 1 + 2;
        if (self.message_expiry != null) size += 1 + 4;
        if (self.payload_format != null) size += 1 + 1;
        if (self.content_type) |s| size += 1 + 2 + s.len;
        if (self.response_topic) |s| size += 1 + 2 + s.len;
        if (self.correlation_data) |d| size += 1 + 2 + d.len;
        if (self.subscription_id) |v| size += 1 + variableIntSize(v);
        if (self.will_delay_interval != null) size += 1 + 4;
        if (self.auth_method) |s| size += 1 + 2 + s.len;
        if (self.auth_data) |d| size += 1 + 2 + d.len;
        if (self.reason_string) |s| size += 1 + 2 + s.len;
        if (self.response_info) |s| size += 1 + 2 + s.len;
        if (self.server_reference) |s| size += 1 + 2 + s.len;
        if (self.request_problem_info != null) size += 1 + 1;
        if (self.request_response_info != null) size += 1 + 1;

        for (self.user_properties[0..self.user_property_count]) |up| {
            size += 1 + 2 + up.key.len + 2 + up.value.len;
        }

        return size;
    }
};

// ============================================================================
// Encode Properties
// ============================================================================

pub fn encodeProperties(buf: []u8, props: *const Properties) Error!usize {
    const props_size = props.encodedSize();
    const len_size = variableIntSize(@truncate(props_size));

    if (buf.len < len_size + props_size) return Error.BufferTooSmall;

    var offset = try encodeVariableInt(buf, @truncate(props_size));

    // Encode each property
    if (props.session_expiry) |v| {
        buf[offset] = @intFromEnum(PropertyId.session_expiry);
        offset += 1;
        offset += try encodeU32(buf[offset..], v);
    }
    if (props.receive_maximum) |v| {
        buf[offset] = @intFromEnum(PropertyId.receive_maximum);
        offset += 1;
        offset += try encodeU16(buf[offset..], v);
    }
    if (props.maximum_qos) |v| {
        buf[offset] = @intFromEnum(PropertyId.maximum_qos);
        offset += 1;
        buf[offset] = v;
        offset += 1;
    }
    if (props.retain_available) |v| {
        buf[offset] = @intFromEnum(PropertyId.retain_available);
        offset += 1;
        buf[offset] = if (v) 1 else 0;
        offset += 1;
    }
    if (props.maximum_packet_size) |v| {
        buf[offset] = @intFromEnum(PropertyId.maximum_packet_size);
        offset += 1;
        offset += try encodeU32(buf[offset..], v);
    }
    if (props.assigned_client_id) |s| {
        buf[offset] = @intFromEnum(PropertyId.assigned_client_id);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.topic_alias_maximum) |v| {
        buf[offset] = @intFromEnum(PropertyId.topic_alias_maximum);
        offset += 1;
        offset += try encodeU16(buf[offset..], v);
    }
    if (props.server_keep_alive) |v| {
        buf[offset] = @intFromEnum(PropertyId.server_keep_alive);
        offset += 1;
        offset += try encodeU16(buf[offset..], v);
    }
    if (props.wildcard_sub_available) |v| {
        buf[offset] = @intFromEnum(PropertyId.wildcard_sub_available);
        offset += 1;
        buf[offset] = if (v) 1 else 0;
        offset += 1;
    }
    if (props.sub_id_available) |v| {
        buf[offset] = @intFromEnum(PropertyId.sub_id_available);
        offset += 1;
        buf[offset] = if (v) 1 else 0;
        offset += 1;
    }
    if (props.shared_sub_available) |v| {
        buf[offset] = @intFromEnum(PropertyId.shared_sub_available);
        offset += 1;
        buf[offset] = if (v) 1 else 0;
        offset += 1;
    }
    if (props.topic_alias) |v| {
        buf[offset] = @intFromEnum(PropertyId.topic_alias);
        offset += 1;
        offset += try encodeU16(buf[offset..], v);
    }
    if (props.message_expiry) |v| {
        buf[offset] = @intFromEnum(PropertyId.message_expiry);
        offset += 1;
        offset += try encodeU32(buf[offset..], v);
    }
    if (props.payload_format) |v| {
        buf[offset] = @intFromEnum(PropertyId.payload_format);
        offset += 1;
        buf[offset] = v;
        offset += 1;
    }
    if (props.content_type) |s| {
        buf[offset] = @intFromEnum(PropertyId.content_type);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.response_topic) |s| {
        buf[offset] = @intFromEnum(PropertyId.response_topic);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.correlation_data) |d| {
        buf[offset] = @intFromEnum(PropertyId.correlation_data);
        offset += 1;
        offset += try encodeBinary(buf[offset..], d);
    }
    if (props.subscription_id) |v| {
        buf[offset] = @intFromEnum(PropertyId.subscription_id);
        offset += 1;
        offset += try encodeVariableInt(buf[offset..], v);
    }
    if (props.will_delay_interval) |v| {
        buf[offset] = @intFromEnum(PropertyId.will_delay_interval);
        offset += 1;
        offset += try encodeU32(buf[offset..], v);
    }
    if (props.auth_method) |s| {
        buf[offset] = @intFromEnum(PropertyId.auth_method);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.auth_data) |d| {
        buf[offset] = @intFromEnum(PropertyId.auth_data);
        offset += 1;
        offset += try encodeBinary(buf[offset..], d);
    }
    if (props.reason_string) |s| {
        buf[offset] = @intFromEnum(PropertyId.reason_string);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.response_info) |s| {
        buf[offset] = @intFromEnum(PropertyId.response_info);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.server_reference) |s| {
        buf[offset] = @intFromEnum(PropertyId.server_reference);
        offset += 1;
        offset += try encodeString(buf[offset..], s);
    }
    if (props.request_problem_info) |v| {
        buf[offset] = @intFromEnum(PropertyId.request_problem_info);
        offset += 1;
        buf[offset] = v;
        offset += 1;
    }
    if (props.request_response_info) |v| {
        buf[offset] = @intFromEnum(PropertyId.request_response_info);
        offset += 1;
        buf[offset] = v;
        offset += 1;
    }

    for (props.user_properties[0..props.user_property_count]) |up| {
        buf[offset] = @intFromEnum(PropertyId.user_property);
        offset += 1;
        offset += try encodeString(buf[offset..], up.key);
        offset += try encodeString(buf[offset..], up.value);
    }

    return offset;
}

/// Encode empty properties (just the zero-length prefix)
pub fn encodeEmptyProperties(buf: []u8) Error!usize {
    if (buf.len < 1) return Error.BufferTooSmall;
    buf[0] = 0;
    return 1;
}

// ============================================================================
// Decode Properties
// ============================================================================

pub fn decodeProperties(buf: []const u8) Error!struct { props: Properties, len: usize } {
    if (buf.len == 0) return .{ .props = .{}, .len = 0 };

    const len_result = try decodeVariableInt(buf);
    const props_len = len_result.value;
    const header_len = len_result.len;

    if (buf.len < header_len + props_len) return Error.MalformedPacket;

    var props = Properties{};
    var offset: usize = header_len;
    const end_offset = header_len + props_len;

    while (offset < end_offset) {
        if (offset >= buf.len) return Error.MalformedPacket;

        const prop_id_raw = buf[offset];
        offset += 1;

        switch (prop_id_raw) {
            @intFromEnum(PropertyId.session_expiry) => {
                props.session_expiry = try decodeU32(buf[offset..]);
                offset += 4;
            },
            @intFromEnum(PropertyId.receive_maximum) => {
                props.receive_maximum = try decodeU16(buf[offset..]);
                offset += 2;
            },
            @intFromEnum(PropertyId.maximum_qos) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.maximum_qos = buf[offset];
                offset += 1;
            },
            @intFromEnum(PropertyId.retain_available) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.retain_available = buf[offset] != 0;
                offset += 1;
            },
            @intFromEnum(PropertyId.maximum_packet_size) => {
                props.maximum_packet_size = try decodeU32(buf[offset..]);
                offset += 4;
            },
            @intFromEnum(PropertyId.assigned_client_id) => {
                const r = try decodeString(buf[offset..]);
                props.assigned_client_id = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.topic_alias_maximum) => {
                props.topic_alias_maximum = try decodeU16(buf[offset..]);
                offset += 2;
            },
            @intFromEnum(PropertyId.server_keep_alive) => {
                props.server_keep_alive = try decodeU16(buf[offset..]);
                offset += 2;
            },
            @intFromEnum(PropertyId.wildcard_sub_available) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.wildcard_sub_available = buf[offset] != 0;
                offset += 1;
            },
            @intFromEnum(PropertyId.sub_id_available) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.sub_id_available = buf[offset] != 0;
                offset += 1;
            },
            @intFromEnum(PropertyId.shared_sub_available) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.shared_sub_available = buf[offset] != 0;
                offset += 1;
            },
            @intFromEnum(PropertyId.topic_alias) => {
                props.topic_alias = try decodeU16(buf[offset..]);
                offset += 2;
            },
            @intFromEnum(PropertyId.message_expiry) => {
                props.message_expiry = try decodeU32(buf[offset..]);
                offset += 4;
            },
            @intFromEnum(PropertyId.payload_format) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.payload_format = buf[offset];
                offset += 1;
            },
            @intFromEnum(PropertyId.content_type) => {
                const r = try decodeString(buf[offset..]);
                props.content_type = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.response_topic) => {
                const r = try decodeString(buf[offset..]);
                props.response_topic = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.correlation_data) => {
                const r = try decodeBinary(buf[offset..]);
                props.correlation_data = r.data;
                offset += r.len;
            },
            @intFromEnum(PropertyId.subscription_id) => {
                const r = try decodeVariableInt(buf[offset..]);
                props.subscription_id = r.value;
                offset += r.len;
            },
            @intFromEnum(PropertyId.will_delay_interval) => {
                props.will_delay_interval = try decodeU32(buf[offset..]);
                offset += 4;
            },
            @intFromEnum(PropertyId.auth_method) => {
                const r = try decodeString(buf[offset..]);
                props.auth_method = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.auth_data) => {
                const r = try decodeBinary(buf[offset..]);
                props.auth_data = r.data;
                offset += r.len;
            },
            @intFromEnum(PropertyId.reason_string) => {
                const r = try decodeString(buf[offset..]);
                props.reason_string = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.response_info) => {
                const r = try decodeString(buf[offset..]);
                props.response_info = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.server_reference) => {
                const r = try decodeString(buf[offset..]);
                props.server_reference = r.str;
                offset += r.len;
            },
            @intFromEnum(PropertyId.request_problem_info) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.request_problem_info = buf[offset];
                offset += 1;
            },
            @intFromEnum(PropertyId.request_response_info) => {
                if (offset >= buf.len) return Error.MalformedPacket;
                props.request_response_info = buf[offset];
                offset += 1;
            },
            @intFromEnum(PropertyId.user_property) => {
                const key_r = try decodeString(buf[offset..]);
                offset += key_r.len;
                const val_r = try decodeString(buf[offset..]);
                offset += val_r.len;

                if (props.user_property_count < max_user_properties) {
                    props.user_properties[props.user_property_count] = .{
                        .key = key_r.str,
                        .value = val_r.str,
                    };
                    props.user_property_count += 1;
                }
                // If over limit, silently skip (don't error)
            },
            else => {
                // Skip unknown properties by returning error
                // (Go mqtt0 also errors on unknown properties)
                return Error.MalformedPacket;
            },
        }
    }

    return .{ .props = props, .len = end_offset };
}

// ============================================================================
// Decoded Packets
// ============================================================================

pub const max_topics = 32;

pub const Connect = struct {
    client_id: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    clean_start: bool = true,
    keep_alive: u16 = 60,
    props: Properties = .{},
    will_topic: ?[]const u8 = null,
    will_message: ?[]const u8 = null,
    will_qos: QoS = .at_most_once,
    will_retain: bool = false,
    will_props: Properties = .{},
};

pub const ConnAck = struct {
    session_present: bool,
    reason_code: ReasonCode,
    props: Properties = .{},
};

pub const Publish = struct {
    topic: []const u8,
    payload: []const u8,
    retain: bool,
    qos: QoS,
    dup: bool,
    packet_id: u16,
    props: Properties = .{},
};

pub const SubscribeFilter = struct {
    topic: []const u8,
    qos: QoS = .at_most_once,
    no_local: bool = false,
    retain_as_published: bool = false,
    retain_handling: u2 = 0,
};

pub const Subscribe = struct {
    packet_id: u16,
    props: Properties = .{},
    filters: [max_topics]SubscribeFilter = undefined,
    filter_count: usize = 0,
};

pub const SubAck = struct {
    packet_id: u16,
    props: Properties = .{},
    reason_codes: [max_topics]ReasonCode = undefined,
    reason_code_count: usize = 0,
};

pub const Unsubscribe = struct {
    packet_id: u16,
    props: Properties = .{},
    topics: [max_topics][]const u8 = undefined,
    topic_count: usize = 0,
};

pub const UnsubAck = struct {
    packet_id: u16,
    props: Properties = .{},
    reason_codes: [max_topics]ReasonCode = undefined,
    reason_code_count: usize = 0,
};

pub const Disconnect = struct {
    reason_code: ReasonCode = .success,
    props: Properties = .{},
};

pub const DecodedPacket = union(PacketType) {
    reserved: void,
    connect: Connect,
    connack: ConnAck,
    publish: Publish,
    puback: u16,
    pubrec: u16,
    pubrel: u16,
    pubcomp: u16,
    subscribe: Subscribe,
    suback: SubAck,
    unsubscribe: Unsubscribe,
    unsuback: UnsubAck,
    pingreq: void,
    pingresp: void,
    disconnect: Disconnect,
    auth: void,
};

// ============================================================================
// Encode: CONNECT
// ============================================================================

pub fn encodeConnect(buf: []u8, config: *const pkt.ConnectConfig, connect_props: *const Properties) Error!usize {
    // Calculate sizes
    var var_header_size: usize = 0;
    var_header_size += 2 + pkt.protocol_name.len; // Protocol name
    var_header_size += 1; // Protocol level
    var_header_size += 1; // Connect flags
    var_header_size += 2; // Keep alive

    // Properties
    const props_data_size = connect_props.encodedSize();
    var_header_size += variableIntSize(@truncate(props_data_size)) + props_data_size;

    var payload_size: usize = 0;
    payload_size += 2 + config.client_id.len;

    if (config.will_topic) |topic| {
        payload_size += 1; // Empty will properties (length = 0)
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

    var offset = try encodeFixedHeader(buf, .connect, 0, remaining_len);
    offset += try encodeString(buf[offset..], pkt.protocol_name);

    buf[offset] = pkt.protocol_version_v5;
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
    offset += try encodeProperties(buf[offset..], connect_props);

    // Payload
    offset += try encodeString(buf[offset..], config.client_id);

    if (config.will_topic) |topic| {
        offset += try encodeEmptyProperties(buf[offset..]);
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

pub fn encodeConnAck(buf: []u8, session_present: bool, reason_code: ReasonCode, props: *const Properties) Error!usize {
    // Calculate remaining length
    const props_data_size = props.encodedSize();
    const props_total = variableIntSize(@truncate(props_data_size)) + props_data_size;
    const remaining_len: u32 = @truncate(2 + props_total); // flags + reason + props

    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .connack, 0, remaining_len);
    buf[offset] = if (session_present) 0x01 else 0x00;
    offset += 1;
    buf[offset] = @intFromEnum(reason_code);
    offset += 1;
    offset += try encodeProperties(buf[offset..], props);

    return offset;
}

// ============================================================================
// Encode: PUBLISH
// ============================================================================

pub fn encodePublish(buf: []u8, opts: *const pkt.PublishOptions, props: *const Properties) Error!usize {
    var var_header_size: usize = 0;
    var_header_size += 2 + opts.topic.len;
    if (@intFromEnum(opts.qos) > 0) var_header_size += 2;

    const props_data_size = props.encodedSize();
    var_header_size += variableIntSize(@truncate(props_data_size)) + props_data_size;

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

    offset += try encodeProperties(buf[offset..], props);

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
        payload_size += 2 + topic.len + 1; // String + subscription options
    }

    const remaining_len: u32 = @truncate(2 + 1 + payload_size); // Packet ID + empty props + topics
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .subscribe, 0x02, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);
    offset += try encodeEmptyProperties(buf[offset..]);

    for (topics) |topic| {
        offset += try encodeString(buf[offset..], topic);
        buf[offset] = 0x00; // QoS 0, no options
        offset += 1;
    }

    return offset;
}

// ============================================================================
// Encode: SUBACK
// ============================================================================

pub fn encodeSubAck(buf: []u8, packet_id: u16, reason_codes: []const ReasonCode) Error!usize {
    const remaining_len: u32 = @truncate(2 + 1 + reason_codes.len); // Packet ID + empty props + codes
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .suback, 0, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);
    offset += try encodeEmptyProperties(buf[offset..]);

    for (reason_codes) |code| {
        buf[offset] = @intFromEnum(code);
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

    const remaining_len: u32 = @truncate(2 + 1 + payload_size); // Packet ID + empty props + topics
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .unsubscribe, 0x02, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);
    offset += try encodeEmptyProperties(buf[offset..]);

    for (topics) |topic| {
        offset += try encodeString(buf[offset..], topic);
    }

    return offset;
}

// ============================================================================
// Encode: UNSUBACK
// ============================================================================

pub fn encodeUnsubAck(buf: []u8, packet_id: u16, reason_codes: []const ReasonCode) Error!usize {
    const remaining_len: u32 = @truncate(2 + 1 + reason_codes.len);
    const header_size = 1 + variableIntSize(remaining_len);
    if (buf.len < header_size + remaining_len) return Error.BufferTooSmall;

    var offset = try encodeFixedHeader(buf, .unsuback, 0, remaining_len);
    offset += try encodeU16(buf[offset..], packet_id);
    offset += try encodeEmptyProperties(buf[offset..]);

    for (reason_codes) |code| {
        buf[offset] = @intFromEnum(code);
        offset += 1;
    }

    return offset;
}

// ============================================================================
// Encode: PINGREQ / PINGRESP
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

// ============================================================================
// Encode: DISCONNECT
// ============================================================================

pub fn encodeDisconnect(buf: []u8, reason_code: ReasonCode) Error!usize {
    if (reason_code == .success) {
        if (buf.len < 2) return Error.BufferTooSmall;
        buf[0] = @as(u8, @intFromEnum(PacketType.disconnect)) << 4;
        buf[1] = 0;
        return 2;
    }

    if (buf.len < 4) return Error.BufferTooSmall;
    buf[0] = @as(u8, @intFromEnum(PacketType.disconnect)) << 4;
    buf[1] = 2; // remaining: reason + empty props
    buf[2] = @intFromEnum(reason_code);
    buf[3] = 0; // Empty properties
    return 4;
}

// ============================================================================
// Decode: Generic
// ============================================================================

pub fn decodePacket(buf: []const u8) Error!struct { packet: DecodedPacket, len: usize } {
    const header = try decodeFixedHeader(buf);
    const total_len = header.totalLen();

    if (buf.len < total_len) return Error.MalformedPacket;

    const payload = buf[header.header_len..total_len];

    const decoded: DecodedPacket = switch (header.packet_type) {
        .connect => .{ .connect = try decodeConnect(payload) },
        .connack => .{ .connack = try decodeConnAck(payload) },
        .publish => .{ .publish = try decodePublish(payload, header.flags, header.remaining_len) },
        .subscribe => .{ .subscribe = try decodeSubscribe(payload) },
        .suback => .{ .suback = try decodeSubAck(payload, header.remaining_len) },
        .unsubscribe => .{ .unsubscribe = try decodeUnsubscribe(payload) },
        .unsuback => .{ .unsuback = try decodeUnsubAck(payload, header.remaining_len) },
        .pingreq => .{ .pingreq = {} },
        .pingresp => .{ .pingresp = {} },
        .disconnect => .{ .disconnect = try decodeDisconnect(payload, header.remaining_len) },
        else => return Error.UnknownPacketType,
    };

    return .{ .packet = decoded, .len = total_len };
}

// ============================================================================
// Decode: CONNECT
// ============================================================================

fn decodeConnect(buf: []const u8) Error!Connect {
    var offset: usize = 0;

    const name_result = try decodeString(buf[offset..]);
    offset += name_result.len;

    if (offset >= buf.len) return Error.MalformedPacket;
    if (buf[offset] != pkt.protocol_version_v5) return Error.UnsupportedProtocolVersion;
    offset += 1;

    if (offset >= buf.len) return Error.MalformedPacket;
    const flags = buf[offset];
    offset += 1;

    const clean_start = flags & 0x02 != 0;
    const will_flag = flags & 0x04 != 0;
    const will_qos: QoS = @enumFromInt((flags >> 3) & 0x03);
    const will_retain = flags & 0x20 != 0;
    const password_flag = flags & 0x40 != 0;
    const username_flag = flags & 0x80 != 0;

    const keep_alive = try decodeU16(buf[offset..]);
    offset += 2;

    const props_result = try decodeProperties(buf[offset..]);
    offset += props_result.len;

    const client_id_result = try decodeString(buf[offset..]);
    offset += client_id_result.len;

    var result = Connect{
        .client_id = client_id_result.str,
        .clean_start = clean_start,
        .keep_alive = keep_alive,
        .props = props_result.props,
    };

    if (will_flag) {
        const will_props_result = try decodeProperties(buf[offset..]);
        offset += will_props_result.len;
        result.will_props = will_props_result.props;

        const will_topic_result = try decodeString(buf[offset..]);
        offset += will_topic_result.len;
        result.will_topic = will_topic_result.str;

        const will_msg_result = try decodeBinary(buf[offset..]);
        offset += will_msg_result.len;
        result.will_message = will_msg_result.data;
        result.will_qos = will_qos;
        result.will_retain = will_retain;
    }

    if (username_flag) {
        const r = try decodeString(buf[offset..]);
        offset += r.len;
        result.username = r.str;
    }

    if (password_flag) {
        const r = try decodeBinary(buf[offset..]);
        offset += r.len;
        result.password = r.data;
    }

    return result;
}

// ============================================================================
// Decode: CONNACK
// ============================================================================

fn decodeConnAck(buf: []const u8) Error!ConnAck {
    if (buf.len < 2) return Error.MalformedPacket;

    const session_present = buf[0] & 0x01 != 0;
    const reason_code: ReasonCode = @enumFromInt(buf[1]);

    var props = Properties{};
    if (buf.len > 2) {
        const props_result = try decodeProperties(buf[2..]);
        props = props_result.props;
    }

    return .{
        .session_present = session_present,
        .reason_code = reason_code,
        .props = props,
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

    const props_result = try decodeProperties(buf[offset..]);
    offset += props_result.len;

    const payload_len = remaining_len - @as(u32, @truncate(offset));
    const payload = buf[offset .. offset + payload_len];

    return .{
        .topic = topic_result.str,
        .payload = payload,
        .retain = retain,
        .qos = qos,
        .dup = dup,
        .packet_id = packet_id,
        .props = props_result.props,
    };
}

// ============================================================================
// Decode: SUBSCRIBE
// ============================================================================

fn decodeSubscribe(buf: []const u8) Error!Subscribe {
    var offset: usize = 0;

    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    const props_result = try decodeProperties(buf[offset..]);
    offset += props_result.len;

    var result = Subscribe{
        .packet_id = packet_id,
        .props = props_result.props,
    };

    while (offset < buf.len) {
        if (result.filter_count >= max_topics) break;

        const topic_result = try decodeString(buf[offset..]);
        offset += topic_result.len;

        if (offset >= buf.len) return Error.MalformedPacket;
        const opts = buf[offset];
        offset += 1;

        result.filters[result.filter_count] = .{
            .topic = topic_result.str,
            .qos = @enumFromInt(opts & 0x03),
            .no_local = opts & 0x04 != 0,
            .retain_as_published = opts & 0x08 != 0,
            .retain_handling = @truncate((opts >> 4) & 0x03),
        };
        result.filter_count += 1;
    }

    return result;
}

// ============================================================================
// Decode: SUBACK
// ============================================================================

fn decodeSubAck(buf: []const u8, remaining_len: u32) Error!SubAck {
    var offset: usize = 0;

    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    const props_result = try decodeProperties(buf[offset..]);
    offset += props_result.len;

    var result = SubAck{
        .packet_id = packet_id,
        .props = props_result.props,
    };

    while (offset < remaining_len and result.reason_code_count < max_topics) {
        if (offset >= buf.len) break;
        result.reason_codes[result.reason_code_count] = @enumFromInt(buf[offset]);
        result.reason_code_count += 1;
        offset += 1;
    }

    return result;
}

// ============================================================================
// Decode: UNSUBSCRIBE
// ============================================================================

fn decodeUnsubscribe(buf: []const u8) Error!Unsubscribe {
    var offset: usize = 0;

    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    const props_result = try decodeProperties(buf[offset..]);
    offset += props_result.len;

    var result = Unsubscribe{
        .packet_id = packet_id,
        .props = props_result.props,
    };

    while (offset < buf.len) {
        if (result.topic_count >= max_topics) break;

        const topic_result = try decodeString(buf[offset..]);
        offset += topic_result.len;

        result.topics[result.topic_count] = topic_result.str;
        result.topic_count += 1;
    }

    return result;
}

// ============================================================================
// Decode: UNSUBACK
// ============================================================================

fn decodeUnsubAck(buf: []const u8, remaining_len: u32) Error!UnsubAck {
    var offset: usize = 0;

    const packet_id = try decodeU16(buf[offset..]);
    offset += 2;

    const props_result = try decodeProperties(buf[offset..]);
    offset += props_result.len;

    var result = UnsubAck{
        .packet_id = packet_id,
        .props = props_result.props,
    };

    while (offset < remaining_len and result.reason_code_count < max_topics) {
        if (offset >= buf.len) break;
        result.reason_codes[result.reason_code_count] = @enumFromInt(buf[offset]);
        result.reason_code_count += 1;
        offset += 1;
    }

    return result;
}

// ============================================================================
// Decode: DISCONNECT
// ============================================================================

fn decodeDisconnect(buf: []const u8, remaining_len: u32) Error!Disconnect {
    if (remaining_len == 0) {
        return .{};
    }

    if (buf.len < 1) return Error.MalformedPacket;

    const reason_code: ReasonCode = @enumFromInt(buf[0]);

    var props = Properties{};
    if (remaining_len > 1 and buf.len > 1) {
        const props_result = try decodeProperties(buf[1..]);
        props = props_result.props;
    }

    return .{
        .reason_code = reason_code,
        .props = props,
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

test "v5 properties encode/decode roundtrip" {
    var buf: [512]u8 = undefined;

    const props = Properties{
        .session_expiry = 3600,
        .receive_maximum = 100,
        .maximum_qos = 0,
        .retain_available = true,
        .maximum_packet_size = 1048576,
        .topic_alias_maximum = 32,
        .server_keep_alive = 120,
        .wildcard_sub_available = true,
        .sub_id_available = true,
        .shared_sub_available = false,
        .topic_alias = 5,
        .message_expiry = 7200,
        .payload_format = 1,
        .content_type = "application/json",
        .response_topic = "reply/topic",
        .reason_string = "OK",
    };

    const n = try encodeProperties(&buf, &props);
    const result = try decodeProperties(buf[0..n]);
    const d = result.props;

    try testing.expectEqual(@as(u32, 3600), d.session_expiry.?);
    try testing.expectEqual(@as(u16, 100), d.receive_maximum.?);
    try testing.expectEqual(@as(u8, 0), d.maximum_qos.?);
    try testing.expectEqual(true, d.retain_available.?);
    try testing.expectEqual(@as(u32, 1048576), d.maximum_packet_size.?);
    try testing.expectEqual(@as(u16, 32), d.topic_alias_maximum.?);
    try testing.expectEqual(@as(u16, 120), d.server_keep_alive.?);
    try testing.expectEqual(true, d.wildcard_sub_available.?);
    try testing.expectEqual(true, d.sub_id_available.?);
    try testing.expectEqual(false, d.shared_sub_available.?);
    try testing.expectEqual(@as(u16, 5), d.topic_alias.?);
    try testing.expectEqual(@as(u32, 7200), d.message_expiry.?);
    try testing.expectEqual(@as(u8, 1), d.payload_format.?);
    try testing.expectEqualSlices(u8, "application/json", d.content_type.?);
    try testing.expectEqualSlices(u8, "reply/topic", d.response_topic.?);
    try testing.expectEqualSlices(u8, "OK", d.reason_string.?);
}

test "v5 empty properties roundtrip" {
    var buf: [8]u8 = undefined;
    const n = try encodeEmptyProperties(&buf);
    try testing.expectEqual(@as(usize, 1), n);

    const result = try decodeProperties(buf[0..n]);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expectEqual(@as(?u32, null), result.props.session_expiry);
}

test "v5 user properties roundtrip" {
    var buf: [256]u8 = undefined;

    var props = Properties{};
    props.user_properties[0] = .{ .key = "key1", .value = "val1" };
    props.user_properties[1] = .{ .key = "key2", .value = "val2" };
    props.user_property_count = 2;

    const n = try encodeProperties(&buf, &props);
    const result = try decodeProperties(buf[0..n]);

    try testing.expectEqual(@as(usize, 2), result.props.user_property_count);
    try testing.expectEqualSlices(u8, "key1", result.props.user_properties[0].key);
    try testing.expectEqualSlices(u8, "val1", result.props.user_properties[0].value);
    try testing.expectEqualSlices(u8, "key2", result.props.user_properties[1].key);
    try testing.expectEqualSlices(u8, "val2", result.props.user_properties[1].value);
}

test "v5 CONNECT encode/decode roundtrip" {
    var buf: [512]u8 = undefined;

    const config = pkt.ConnectConfig{
        .client_id = "v5-client",
        .username = "admin",
        .password = "secret",
        .clean_start = true,
        .keep_alive = 120,
        .protocol_version = .v5,
    };

    var props = Properties{};
    props.session_expiry = 3600;
    props.topic_alias_maximum = 16;

    const n = try encodeConnect(&buf, &config, &props);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .connect => |conn| {
            try testing.expectEqualSlices(u8, "v5-client", conn.client_id);
            try testing.expectEqualSlices(u8, "admin", conn.username.?);
            try testing.expectEqualSlices(u8, "secret", conn.password.?);
            try testing.expectEqual(true, conn.clean_start);
            try testing.expectEqual(@as(u16, 120), conn.keep_alive);
            try testing.expectEqual(@as(u32, 3600), conn.props.session_expiry.?);
            try testing.expectEqual(@as(u16, 16), conn.props.topic_alias_maximum.?);
        },
        else => return error.TestExpectedEqual,
    }
}

test "v5 CONNACK encode/decode roundtrip" {
    var buf: [128]u8 = undefined;

    var props = Properties{};
    props.topic_alias_maximum = 32;
    props.server_keep_alive = 60;
    props.retain_available = true;

    const n = try encodeConnAck(&buf, false, .success, &props);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .connack => |ack| {
            try testing.expectEqual(false, ack.session_present);
            try testing.expectEqual(ReasonCode.success, ack.reason_code);
            try testing.expectEqual(@as(u16, 32), ack.props.topic_alias_maximum.?);
            try testing.expectEqual(@as(u16, 60), ack.props.server_keep_alive.?);
            try testing.expectEqual(true, ack.props.retain_available.?);
        },
        else => return error.TestExpectedEqual,
    }
}

test "v5 PUBLISH with topic alias" {
    var buf: [256]u8 = undefined;

    const opts = pkt.PublishOptions{
        .topic = "sensor/temp",
        .payload = "{\"value\":22.5}",
        .retain = false,
    };

    var props = Properties{};
    props.topic_alias = 3;
    props.payload_format = 1; // UTF-8
    props.content_type = "application/json";

    const n = try encodePublish(&buf, &opts, &props);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .publish => |pub_pkt| {
            try testing.expectEqualSlices(u8, "sensor/temp", pub_pkt.topic);
            try testing.expectEqualSlices(u8, "{\"value\":22.5}", pub_pkt.payload);
            try testing.expectEqual(@as(u16, 3), pub_pkt.props.topic_alias.?);
            try testing.expectEqual(@as(u8, 1), pub_pkt.props.payload_format.?);
            try testing.expectEqualSlices(u8, "application/json", pub_pkt.props.content_type.?);
        },
        else => return error.TestExpectedEqual,
    }
}

test "v5 SUBSCRIBE/SUBACK roundtrip" {
    var buf: [256]u8 = undefined;

    {
        const topics = [_][]const u8{ "sensor/+/data", "device/#" };
        const n = try encodeSubscribe(&buf, 42, &topics);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .subscribe => |sub| {
                try testing.expectEqual(@as(u16, 42), sub.packet_id);
                try testing.expectEqual(@as(usize, 2), sub.filter_count);
                try testing.expectEqualSlices(u8, "sensor/+/data", sub.filters[0].topic);
                try testing.expectEqualSlices(u8, "device/#", sub.filters[1].topic);
            },
            else => return error.TestExpectedEqual,
        }
    }

    {
        const codes = [_]ReasonCode{ .success, .success };
        const n = try encodeSubAck(&buf, 42, &codes);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .suback => |ack| {
                try testing.expectEqual(@as(u16, 42), ack.packet_id);
                try testing.expectEqual(@as(usize, 2), ack.reason_code_count);
                try testing.expectEqual(ReasonCode.success, ack.reason_codes[0]);
            },
            else => return error.TestExpectedEqual,
        }
    }
}

test "v5 UNSUBSCRIBE/UNSUBACK roundtrip" {
    var buf: [256]u8 = undefined;

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

    {
        const codes = [_]ReasonCode{.success};
        const n = try encodeUnsubAck(&buf, 7, &codes);
        const result = try decodePacket(buf[0..n]);

        switch (result.packet) {
            .unsuback => |ack| {
                try testing.expectEqual(@as(u16, 7), ack.packet_id);
                try testing.expectEqual(@as(usize, 1), ack.reason_code_count);
            },
            else => return error.TestExpectedEqual,
        }
    }
}

test "v5 DISCONNECT roundtrip" {
    var buf: [16]u8 = undefined;

    // Normal disconnect (empty)
    {
        const n = try encodeDisconnect(&buf, .success);
        try testing.expectEqual(@as(usize, 2), n);
        const result = try decodePacket(buf[0..n]);
        switch (result.packet) {
            .disconnect => |disc| {
                try testing.expectEqual(ReasonCode.success, disc.reason_code);
            },
            else => return error.TestExpectedEqual,
        }
    }

    // Disconnect with reason
    {
        const n = try encodeDisconnect(&buf, .not_authorized);
        try testing.expectEqual(@as(usize, 4), n);
        const result = try decodePacket(buf[0..n]);
        switch (result.packet) {
            .disconnect => |disc| {
                try testing.expectEqual(ReasonCode.not_authorized, disc.reason_code);
            },
            else => return error.TestExpectedEqual,
        }
    }
}

test "v5 PINGREQ/PINGRESP roundtrip" {
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

test "v5 PUBLISH with empty topic (alias-only)" {
    var buf: [128]u8 = undefined;

    const opts = pkt.PublishOptions{
        .topic = "", // Empty topic — alias only
        .payload = "data",
    };

    var props = Properties{};
    props.topic_alias = 5;

    const n = try encodePublish(&buf, &opts, &props);
    const result = try decodePacket(buf[0..n]);

    switch (result.packet) {
        .publish => |pub_pkt| {
            try testing.expectEqual(@as(usize, 0), pub_pkt.topic.len);
            try testing.expectEqual(@as(u16, 5), pub_pkt.props.topic_alias.?);
            try testing.expectEqualSlices(u8, "data", pub_pkt.payload);
        },
        else => return error.TestExpectedEqual,
    }
}
