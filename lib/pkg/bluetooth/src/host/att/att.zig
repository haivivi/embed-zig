//! ATT — Attribute Protocol
//!
//! PDU encode/decode + attribute database for BLE GATT.
//! Pure data transformation — no I/O.
//!
//! ## ATT PDU Format (BT Core Spec Vol 3, Part F)
//!
//! ```
//! [Opcode (1)][Parameters...]
//! ```
//!
//! ## Operations
//!
//! | Opcode | Name                     | Direction        |
//! |--------|--------------------------|------------------|
//! | 0x01   | Error Response           | Server → Client  |
//! | 0x02   | Exchange MTU Request     | Client → Server  |
//! | 0x03   | Exchange MTU Response    | Server → Client  |
//! | 0x04   | Find Information Req     | Client → Server  |
//! | 0x05   | Find Information Resp    | Server → Client  |
//! | 0x06   | Find By Type Value Req   | Client → Server  |
//! | 0x08   | Read By Type Request     | Client → Server  |
//! | 0x09   | Read By Type Response    | Server → Client  |
//! | 0x0A   | Read Request             | Client → Server  |
//! | 0x0B   | Read Response            | Server → Client  |
//! | 0x10   | Read By Group Type Req   | Client → Server  |
//! | 0x11   | Read By Group Type Resp  | Server → Client  |
//! | 0x12   | Write Request            | Client → Server  |
//! | 0x13   | Write Response           | Server → Client  |
//! | 0x1B   | Handle Value Notification| Server → Client  |
//! | 0x1D   | Handle Value Indication  | Server → Client  |
//! | 0x1E   | Handle Value Confirmation| Client → Server  |
//! | 0x52   | Write Command            | Client → Server  |

const std = @import("std");

// ============================================================================
// Opcodes
// ============================================================================

pub const Opcode = enum(u8) {
    error_response = 0x01,
    exchange_mtu_request = 0x02,
    exchange_mtu_response = 0x03,
    find_information_request = 0x04,
    find_information_response = 0x05,
    find_by_type_value_request = 0x06,
    find_by_type_value_response = 0x07,
    read_by_type_request = 0x08,
    read_by_type_response = 0x09,
    read_request = 0x0A,
    read_response = 0x0B,
    read_blob_request = 0x0C,
    read_blob_response = 0x0D,
    read_by_group_type_request = 0x10,
    read_by_group_type_response = 0x11,
    write_request = 0x12,
    write_response = 0x13,
    handle_value_notification = 0x1B,
    handle_value_indication = 0x1D,
    handle_value_confirmation = 0x1E,
    write_command = 0x52,
    _,
};

/// ATT Error Codes
pub const ErrorCode = enum(u8) {
    invalid_handle = 0x01,
    read_not_permitted = 0x02,
    write_not_permitted = 0x03,
    invalid_pdu = 0x04,
    insufficient_authentication = 0x05,
    request_not_supported = 0x06,
    invalid_offset = 0x07,
    insufficient_authorization = 0x08,
    prepare_queue_full = 0x09,
    attribute_not_found = 0x0A,
    attribute_not_long = 0x0B,
    insufficient_encryption_key_size = 0x0C,
    invalid_attribute_value_length = 0x0D,
    unlikely_error = 0x0E,
    insufficient_encryption = 0x0F,
    unsupported_group_type = 0x10,
    insufficient_resources = 0x11,
    _,
};

// ============================================================================
// UUID Types
// ============================================================================

/// BLE UUID (supports 16-bit and 128-bit)
pub const UUID = union(enum) {
    /// 16-bit UUID (Bluetooth SIG assigned)
    uuid16: u16,
    /// 128-bit UUID
    uuid128: [16]u8,

    /// Create a 16-bit UUID
    pub fn from16(v: u16) UUID {
        return .{ .uuid16 = v };
    }

    /// Create a 128-bit UUID
    pub fn from128(v: [16]u8) UUID {
        return .{ .uuid128 = v };
    }

    /// Get byte length of this UUID
    pub fn byteLen(self: UUID) usize {
        return switch (self) {
            .uuid16 => 2,
            .uuid128 => 16,
        };
    }

    /// Write UUID to buffer (little-endian)
    pub fn writeTo(self: UUID, buf: []u8) usize {
        switch (self) {
            .uuid16 => |v| {
                std.mem.writeInt(u16, buf[0..2], v, .little);
                return 2;
            },
            .uuid128 => |v| {
                @memcpy(buf[0..16], &v);
                return 16;
            },
        }
    }

    /// Read UUID from buffer
    pub fn readFrom(buf: []const u8, len: usize) ?UUID {
        if (len == 2 and buf.len >= 2) {
            return .{ .uuid16 = std.mem.readInt(u16, buf[0..2], .little) };
        } else if (len == 16 and buf.len >= 16) {
            return .{ .uuid128 = buf[0..16].* };
        }
        return null;
    }

    pub fn eql(self: UUID, other: UUID) bool {
        return switch (self) {
            .uuid16 => |a| switch (other) {
                .uuid16 => |b| a == b,
                .uuid128 => false,
            },
            .uuid128 => |a| switch (other) {
                .uuid16 => false,
                .uuid128 => |b| std.mem.eql(u8, &a, &b),
            },
        };
    }
};

/// Well-known GATT UUIDs (16-bit)
pub const GATT_PRIMARY_SERVICE_UUID: u16 = 0x2800;
pub const GATT_SECONDARY_SERVICE_UUID: u16 = 0x2801;
pub const GATT_INCLUDE_UUID: u16 = 0x2802;
pub const GATT_CHARACTERISTIC_UUID: u16 = 0x2803;
pub const GATT_CLIENT_CHAR_CONFIG_UUID: u16 = 0x2902;

// ============================================================================
// ATT Max PDU
// ============================================================================

/// Default ATT MTU for BLE
pub const DEFAULT_MTU: u16 = 23;

/// Maximum ATT MTU (limited by L2CAP LE credit flow)
pub const MAX_MTU: u16 = 517;

/// Maximum ATT PDU size
pub const MAX_PDU_LEN = MAX_MTU;

// ============================================================================
// Characteristic Properties
// ============================================================================

pub const CharProps = packed struct {
    broadcast: bool = false,
    read: bool = false,
    write_without_response: bool = false,
    write: bool = false,
    notify: bool = false,
    indicate: bool = false,
    authenticated_writes: bool = false,
    extended_properties: bool = false,
};

// ============================================================================
// Attribute Database
// ============================================================================

/// A single attribute in the database
pub const Attribute = struct {
    /// Attribute handle (assigned sequentially)
    handle: u16,
    /// Attribute type (UUID)
    att_type: UUID,
    /// Attribute value (static)
    value: []const u8,
    /// Permissions
    permissions: Permissions,
};

pub const Permissions = packed struct {
    readable: bool = false,
    writable: bool = false,
    _padding: u6 = 0,
};

/// Attribute database (fixed-size, comptime-built)
pub fn AttributeDb(comptime max_attrs: usize) type {
    return struct {
        const Self = @This();

        attrs: [max_attrs]Attribute = undefined,
        count: usize = 0,

        /// Add an attribute to the database
        pub fn add(self: *Self, attr: Attribute) !u16 {
            if (self.count >= max_attrs) return error.DatabaseFull;
            self.attrs[self.count] = attr;
            self.count += 1;
            return attr.handle;
        }

        /// Find attribute by handle
        pub fn findByHandle(self: *const Self, handle: u16) ?*const Attribute {
            for (self.attrs[0..self.count]) |*attr| {
                if (attr.handle == handle) return attr;
            }
            return null;
        }

        /// Find attributes by type UUID in handle range
        pub fn findByType(
            self: *const Self,
            start_handle: u16,
            end_handle: u16,
            att_type: UUID,
        ) FindIterator(max_attrs) {
            return .{
                .db = self,
                .start = start_handle,
                .end = end_handle,
                .att_type = att_type,
                .index = 0,
            };
        }
    };
}

pub fn FindIterator(comptime max_attrs: usize) type {
    return struct {
        const Self = @This();

        db: *const AttributeDb(max_attrs),
        start: u16,
        end: u16,
        att_type: UUID,
        index: usize,

        pub fn next(self: *Self) ?*const Attribute {
            while (self.index < self.db.count) {
                const attr = &self.db.attrs[self.index];
                self.index += 1;
                if (attr.handle >= self.start and
                    attr.handle <= self.end and
                    attr.att_type.eql(self.att_type))
                {
                    return attr;
                }
            }
            return null;
        }
    };
}

// ============================================================================
// PDU Encoding
// ============================================================================

/// Encode an Error Response PDU
pub fn encodeErrorResponse(
    buf: *[MAX_PDU_LEN]u8,
    request_opcode: Opcode,
    handle: u16,
    error_code: ErrorCode,
) []const u8 {
    buf[0] = @intFromEnum(Opcode.error_response);
    buf[1] = @intFromEnum(request_opcode);
    std.mem.writeInt(u16, buf[2..4], handle, .little);
    buf[4] = @intFromEnum(error_code);
    return buf[0..5];
}

/// Encode an Exchange MTU Response
pub fn encodeMtuResponse(buf: *[MAX_PDU_LEN]u8, mtu: u16) []const u8 {
    buf[0] = @intFromEnum(Opcode.exchange_mtu_response);
    std.mem.writeInt(u16, buf[1..3], mtu, .little);
    return buf[0..3];
}

/// Encode a Read Response
pub fn encodeReadResponse(buf: *[MAX_PDU_LEN]u8, value: []const u8) []const u8 {
    buf[0] = @intFromEnum(Opcode.read_response);
    const len = @min(value.len, MAX_PDU_LEN - 1);
    @memcpy(buf[1..][0..len], value[0..len]);
    return buf[0 .. 1 + len];
}

/// Encode a Write Response (no parameters)
pub fn encodeWriteResponse(buf: *[MAX_PDU_LEN]u8) []const u8 {
    buf[0] = @intFromEnum(Opcode.write_response);
    return buf[0..1];
}

/// Encode a Handle Value Notification
pub fn encodeNotification(buf: *[MAX_PDU_LEN]u8, handle: u16, value: []const u8) []const u8 {
    buf[0] = @intFromEnum(Opcode.handle_value_notification);
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    const len = @min(value.len, MAX_PDU_LEN - 3);
    @memcpy(buf[3..][0..len], value[0..len]);
    return buf[0 .. 3 + len];
}

/// Encode a Handle Value Indication
pub fn encodeIndication(buf: *[MAX_PDU_LEN]u8, handle: u16, value: []const u8) []const u8 {
    buf[0] = @intFromEnum(Opcode.handle_value_indication);
    std.mem.writeInt(u16, buf[1..3], handle, .little);
    const len = @min(value.len, MAX_PDU_LEN - 3);
    @memcpy(buf[3..][0..len], value[0..len]);
    return buf[0 .. 3 + len];
}

// ============================================================================
// PDU Decoding
// ============================================================================

/// Decoded ATT PDU
pub const Pdu = union(enum) {
    exchange_mtu_request: struct { client_mtu: u16 },
    find_information_request: struct { start_handle: u16, end_handle: u16 },
    find_by_type_value_request: struct { start_handle: u16, end_handle: u16, att_type: u16, value: []const u8 },
    read_by_type_request: struct { start_handle: u16, end_handle: u16, uuid: UUID },
    read_request: struct { handle: u16 },
    read_blob_request: struct { handle: u16, offset: u16 },
    read_by_group_type_request: struct { start_handle: u16, end_handle: u16, uuid: UUID },
    write_request: struct { handle: u16, value: []const u8 },
    write_command: struct { handle: u16, value: []const u8 },
    handle_value_confirmation: void,
    unknown: struct { opcode: u8, data: []const u8 },
};

/// Decode an ATT PDU from raw bytes
pub fn decodePdu(data: []const u8) ?Pdu {
    if (data.len < 1) return null;

    const op: Opcode = @enumFromInt(data[0]);
    const params = data[1..];

    return switch (op) {
        .exchange_mtu_request => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .exchange_mtu_request = .{
                .client_mtu = std.mem.readInt(u16, params[0..2], .little),
            } };
        },
        .find_information_request => blk: {
            if (params.len < 4) break :blk null;
            break :blk .{ .find_information_request = .{
                .start_handle = std.mem.readInt(u16, params[0..2], .little),
                .end_handle = std.mem.readInt(u16, params[2..4], .little),
            } };
        },
        .read_by_type_request => blk: {
            if (params.len < 6) break :blk null;
            const uuid_len = params.len - 4;
            const uuid = UUID.readFrom(params[4..], uuid_len) orelse break :blk null;
            break :blk .{ .read_by_type_request = .{
                .start_handle = std.mem.readInt(u16, params[0..2], .little),
                .end_handle = std.mem.readInt(u16, params[2..4], .little),
                .uuid = uuid,
            } };
        },
        .read_request => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .read_request = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
            } };
        },
        .read_blob_request => blk: {
            if (params.len < 4) break :blk null;
            break :blk .{ .read_blob_request = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .offset = std.mem.readInt(u16, params[2..4], .little),
            } };
        },
        .read_by_group_type_request => blk: {
            if (params.len < 6) break :blk null;
            const uuid_len = params.len - 4;
            const uuid = UUID.readFrom(params[4..], uuid_len) orelse break :blk null;
            break :blk .{ .read_by_group_type_request = .{
                .start_handle = std.mem.readInt(u16, params[0..2], .little),
                .end_handle = std.mem.readInt(u16, params[2..4], .little),
                .uuid = uuid,
            } };
        },
        .write_request => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .write_request = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .value = params[2..],
            } };
        },
        .write_command => blk: {
            if (params.len < 2) break :blk null;
            break :blk .{ .write_command = .{
                .handle = std.mem.readInt(u16, params[0..2], .little),
                .value = params[2..],
            } };
        },
        .handle_value_confirmation => .{ .handle_value_confirmation = {} },
        else => .{ .unknown = .{ .opcode = data[0], .data = params } },
    };
}

// ============================================================================
// Tests
// ============================================================================

test "UUID operations" {
    const uuid1 = UUID.from16(0x2800);
    const uuid2 = UUID.from16(0x2800);
    const uuid3 = UUID.from16(0x2801);

    try std.testing.expect(uuid1.eql(uuid2));
    try std.testing.expect(!uuid1.eql(uuid3));
    try std.testing.expectEqual(@as(usize, 2), uuid1.byteLen());

    var buf: [16]u8 = undefined;
    const n = uuid1.writeTo(&buf);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u8, 0x00), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x28), buf[1]);
}

test "encode Error Response" {
    var buf: [MAX_PDU_LEN]u8 = undefined;
    const pdu = encodeErrorResponse(&buf, .read_request, 0x0010, .attribute_not_found);
    try std.testing.expectEqual(@as(usize, 5), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x01), pdu[0]); // Error Response opcode
    try std.testing.expectEqual(@as(u8, 0x0A), pdu[1]); // Request opcode (Read)
    try std.testing.expectEqual(@as(u8, 0x10), pdu[2]); // Handle lo
    try std.testing.expectEqual(@as(u8, 0x00), pdu[3]); // Handle hi
    try std.testing.expectEqual(@as(u8, 0x0A), pdu[4]); // Error: Attribute Not Found
}

test "encode Read Response" {
    var buf: [MAX_PDU_LEN]u8 = undefined;
    const pdu = encodeReadResponse(&buf, "hello");
    try std.testing.expectEqual(@as(usize, 6), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x0B), pdu[0]); // Read Response opcode
    try std.testing.expectEqualStrings("hello", pdu[1..6]);
}

test "encode Notification" {
    var buf: [MAX_PDU_LEN]u8 = undefined;
    const pdu = encodeNotification(&buf, 0x0015, "data");
    try std.testing.expectEqual(@as(usize, 7), pdu.len);
    try std.testing.expectEqual(@as(u8, 0x1B), pdu[0]); // Notification opcode
    try std.testing.expectEqual(@as(u16, 0x0015), std.mem.readInt(u16, pdu[1..3], .little));
    try std.testing.expectEqualStrings("data", pdu[3..7]);
}

test "decode Exchange MTU Request" {
    const data = [_]u8{ 0x02, 0xF7, 0x00 }; // MTU=247
    const pdu = decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .exchange_mtu_request => |mtu_req| {
            try std.testing.expectEqual(@as(u16, 247), mtu_req.client_mtu);
        },
        else => unreachable,
    }
}

test "decode Read Request" {
    const data = [_]u8{ 0x0A, 0x15, 0x00 }; // handle=0x0015
    const pdu = decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .read_request => |rr| {
            try std.testing.expectEqual(@as(u16, 0x0015), rr.handle);
        },
        else => unreachable,
    }
}

test "decode Write Request" {
    const data = [_]u8{ 0x12, 0x15, 0x00, 0xAA, 0xBB };
    const pdu = decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .write_request => |wr| {
            try std.testing.expectEqual(@as(u16, 0x0015), wr.handle);
            try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB }, wr.value);
        },
        else => unreachable,
    }
}

test "decode Read By Group Type Request" {
    const data = [_]u8{ 0x10, 0x01, 0x00, 0xFF, 0xFF, 0x00, 0x28 }; // UUID=0x2800
    const pdu = decodePdu(&data) orelse unreachable;
    switch (pdu) {
        .read_by_group_type_request => |req| {
            try std.testing.expectEqual(@as(u16, 0x0001), req.start_handle);
            try std.testing.expectEqual(@as(u16, 0xFFFF), req.end_handle);
            try std.testing.expect(req.uuid.eql(UUID.from16(0x2800)));
        },
        else => unreachable,
    }
}

test "Attribute database" {
    var db = AttributeDb(16){};

    _ = try db.add(.{
        .handle = 0x0001,
        .att_type = UUID.from16(GATT_PRIMARY_SERVICE_UUID),
        .value = &.{ 0x0D, 0x18 }, // Heart Rate Service UUID
        .permissions = .{ .readable = true },
    });

    _ = try db.add(.{
        .handle = 0x0002,
        .att_type = UUID.from16(GATT_CHARACTERISTIC_UUID),
        .value = &.{ 0x10, 0x03, 0x00, 0x37, 0x2A }, // props + handle + uuid
        .permissions = .{ .readable = true },
    });

    // Find by handle
    const attr = db.findByHandle(0x0001) orelse unreachable;
    try std.testing.expect(attr.att_type.eql(UUID.from16(GATT_PRIMARY_SERVICE_UUID)));

    // Find by type in range
    var iter = db.findByType(0x0001, 0xFFFF, UUID.from16(GATT_PRIMARY_SERVICE_UUID));
    const found = iter.next() orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0001), found.handle);
    try std.testing.expect(iter.next() == null);
}

test "CharProps packed layout" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(CharProps));

    const rw: CharProps = .{ .read = true, .write = true };
    try std.testing.expect(rw.read);
    try std.testing.expect(rw.write);
    try std.testing.expect(!rw.notify);
}
