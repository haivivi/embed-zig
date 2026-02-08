//! HCI ACL Data Packet Format
//!
//! Parse and build HCI ACL data packets (packet indicator 0x02).
//! Used for L2CAP data transfer between Host and Controller.
//!
//! ## ACL Packet Format (BT Core Spec Vol 4, Part E, Section 5.4.2)
//!
//! ```
//! [0x02][Handle+Flags (2)][Data_Length (2)][Data...]
//!
//! Handle+Flags:
//!   bits 0-11:  Connection Handle
//!   bits 12-13: Packet Boundary Flag (PB)
//!   bits 14-15: Broadcast Flag (BC)
//! ```

const std = @import("std");
const hci = @import("hci.zig");

// ============================================================================
// Types
// ============================================================================

/// Packet Boundary Flag
pub const PBFlag = enum(u2) {
    /// First non-automatically-flushable packet of higher layer message
    first_non_auto_flush = 0b00,
    /// Continuing fragment
    continuing = 0b01,
    /// First automatically-flushable packet (default for LE)
    first_auto_flush = 0b10,
    /// Complete L2CAP PDU (automatically flushable)
    complete = 0b11,
};

/// Broadcast Flag (always point-to-point for BLE)
pub const BCFlag = enum(u2) {
    point_to_point = 0b00,
    active_peripheral_broadcast = 0b01,
    _,
};

/// Parsed ACL packet header
pub const AclHeader = struct {
    conn_handle: u16,
    pb_flag: PBFlag,
    bc_flag: BCFlag,
    data_len: u16,
};

/// ACL header size (without indicator byte): 4 bytes
pub const HEADER_LEN = 4;

/// Max ACL data length per BLE spec (LE default: 27, can be up to 251 with DLE)
pub const LE_DEFAULT_DATA_LEN = 27;
pub const LE_MAX_DATA_LEN = 251;

/// Complete ACL packet: indicator(1) + header(4) + data
pub const MAX_PACKET_LEN = 1 + HEADER_LEN + LE_MAX_DATA_LEN;

// ============================================================================
// Parsing
// ============================================================================

/// Parse ACL header from raw bytes (after the 0x02 indicator).
///
/// Input should be at least 4 bytes: [handle_lo][handle_hi_flags][len_lo][len_hi]
pub fn parseHeader(data: []const u8) ?AclHeader {
    if (data.len < HEADER_LEN) return null;

    const handle_flags = std.mem.readInt(u16, data[0..2], .little);
    const data_len = std.mem.readInt(u16, data[2..4], .little);

    return .{
        .conn_handle = handle_flags & 0x0FFF,
        .pb_flag = @enumFromInt(@as(u2, @truncate(handle_flags >> 12))),
        .bc_flag = @enumFromInt(@as(u2, @truncate(handle_flags >> 14))),
        .data_len = data_len,
    };
}

/// Get the payload data from a raw ACL packet (after indicator byte).
///
/// Returns the data portion after the 4-byte header.
pub fn payload(data: []const u8) ?[]const u8 {
    const header = parseHeader(data) orelse return null;
    const total = @as(usize, HEADER_LEN) + header.data_len;
    if (data.len < total) return null;
    return data[HEADER_LEN..total];
}

// ============================================================================
// Building
// ============================================================================

/// Build an ACL packet header + data into a buffer.
///
/// Returns a slice of the complete packet (including 0x02 indicator).
pub fn encode(
    buf: *[MAX_PACKET_LEN]u8,
    conn_handle: u16,
    pb_flag: PBFlag,
    data: []const u8,
) []const u8 {
    std.debug.assert(data.len <= LE_MAX_DATA_LEN);
    std.debug.assert(conn_handle <= 0x0FFF);

    // Indicator
    buf[0] = @intFromEnum(hci.PacketType.acl_data);

    // Handle + flags
    const handle_flags: u16 = conn_handle |
        (@as(u16, @intFromEnum(pb_flag)) << 12) |
        (@as(u16, @intFromEnum(BCFlag.point_to_point)) << 14);
    std.mem.writeInt(u16, buf[1..3], handle_flags, .little);

    // Data length
    std.mem.writeInt(u16, buf[3..5], @intCast(data.len), .little);

    // Data
    @memcpy(buf[5..][0..data.len], data);

    return buf[0 .. 5 + data.len];
}

// ============================================================================
// Tests
// ============================================================================

test "parse ACL header" {
    // Handle=0x0040, PB=first_auto_flush(10), BC=point_to_point(00), len=7
    const raw = [_]u8{
        0x40, 0x20, // handle(0x0040) + pb_flag(0b10) + bc(0b00)
        0x07, 0x00, // data length: 7
        0x03, 0x00, // L2CAP length: 3
        0x04, 0x00, // L2CAP CID: 4 (ATT)
        0x02, 0x01, 0x00, // ATT data
    };

    const hdr = parseHeader(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0040), hdr.conn_handle);
    try std.testing.expectEqual(PBFlag.first_auto_flush, hdr.pb_flag);
    try std.testing.expectEqual(BCFlag.point_to_point, hdr.bc_flag);
    try std.testing.expectEqual(@as(u16, 7), hdr.data_len);

    const pl = payload(&raw) orelse unreachable;
    try std.testing.expectEqual(@as(usize, 7), pl.len);
}

test "encode ACL packet" {
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const data = [_]u8{ 0x03, 0x00, 0x04, 0x00, 0x02, 0x01, 0x00 };
    const pkt = encode(&buf, 0x0040, .first_auto_flush, &data);

    try std.testing.expectEqual(@as(usize, 5 + 7), pkt.len);
    try std.testing.expectEqual(@as(u8, 0x02), pkt[0]); // ACL indicator

    // Parse back
    const hdr = parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0040), hdr.conn_handle);
    try std.testing.expectEqual(PBFlag.first_auto_flush, hdr.pb_flag);
    try std.testing.expectEqual(@as(u16, 7), hdr.data_len);
}

test "round-trip encode/parse" {
    var buf: [MAX_PACKET_LEN]u8 = undefined;
    const original_data = "hello BLE";
    const pkt = encode(&buf, 0x0001, .first_auto_flush, original_data);

    // Skip indicator byte for parsing
    const hdr = parseHeader(pkt[1..]) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 0x0001), hdr.conn_handle);
    try std.testing.expectEqual(@as(u16, 9), hdr.data_len);

    const pl = payload(pkt[1..]) orelse unreachable;
    try std.testing.expectEqualStrings(original_data, pl);
}
