//! L2CAP — Logical Link Control and Adaptation Protocol
//!
//! Fragmentation/reassembly and channel multiplexing for BLE.
//! Pure data transformation — no I/O, no state machines.
//!
//! ## L2CAP Basic Frame Format (BT Core Spec Vol 3, Part A)
//!
//! ```
//! [Length (2)][CID (2)][Information Payload...]
//! ```
//!
//! ## Fixed Channel IDs for BLE
//!
//! | CID    | Channel                |
//! |--------|------------------------|
//! | 0x0004 | ATT                    |
//! | 0x0005 | LE L2CAP Signaling     |
//! | 0x0006 | SMP                    |

const std = @import("std");
const acl = @import("../hci/acl.zig");

// ============================================================================
// Channel IDs
// ============================================================================

/// ATT Bearer (Attribute Protocol)
pub const CID_ATT: u16 = 0x0004;
/// LE L2CAP Signaling
pub const CID_LE_SIGNALING: u16 = 0x0005;
/// Security Manager Protocol
pub const CID_SMP: u16 = 0x0006;

// ============================================================================
// L2CAP Header
// ============================================================================

/// L2CAP header size: 4 bytes (length + CID)
pub const HEADER_LEN = 4;

/// Parsed L2CAP header
pub const Header = struct {
    /// Payload length (excluding this header)
    length: u16,
    /// Channel ID
    cid: u16,
};

/// Parse L2CAP header from data
pub fn parseHeader(data: []const u8) ?Header {
    if (data.len < HEADER_LEN) return null;
    return .{
        .length = std.mem.readInt(u16, data[0..2], .little),
        .cid = std.mem.readInt(u16, data[2..4], .little),
    };
}

// ============================================================================
// Reassembled SDU
// ============================================================================

/// A complete L2CAP SDU (reassembled from ACL fragments)
pub const Sdu = struct {
    /// Connection handle
    conn_handle: u16,
    /// Channel ID
    cid: u16,
    /// SDU payload (points into reassembly buffer)
    data: []const u8,
};

// ============================================================================
// Fragmentation (TX: SDU → ACL fragments)
// ============================================================================

/// Iterator that fragments an L2CAP SDU into ACL packets.
///
/// Usage:
/// ```zig
/// var iter = l2cap.fragmentIterator(sdu, cid, conn_handle, mtu);
/// while (iter.next()) |frag| {
///     // frag is a complete ACL packet (with indicator byte)
///     try host.txQueue.send(frag);
/// }
/// ```
pub const FragmentIterator = struct {
    /// L2CAP SDU (with header prepended)
    sdu_with_header: []const u8,
    conn_handle: u16,
    mtu: u16,
    offset: usize,
    first: bool,
    buf: [acl.MAX_PACKET_LEN]u8,

    pub fn next(self: *FragmentIterator) ?[]const u8 {
        if (self.offset >= self.sdu_with_header.len) return null;

        const remaining = self.sdu_with_header.len - self.offset;
        const chunk_len = @min(remaining, self.mtu);
        const chunk = self.sdu_with_header[self.offset..][0..chunk_len];

        const pb_flag: acl.PBFlag = if (self.first)
            .first_auto_flush
        else
            .continuing;

        const pkt = acl.encode(
            &self.buf,
            self.conn_handle,
            pb_flag,
            chunk,
        );

        self.offset += chunk_len;
        self.first = false;

        return pkt;
    }
};

/// Create a fragment iterator for an L2CAP SDU.
///
/// `sdu` is the raw payload (without L2CAP header).
/// `cid` is the channel ID.
/// `conn_handle` is the ACL connection handle.
/// `mtu` is the max ACL data length (typically 27 for BLE default).
///
/// The iterator prepends the L2CAP header internally and fragments
/// into ACL packets with proper PB flags.
pub fn fragmentIterator(
    sdu_buf: *[acl.LE_MAX_DATA_LEN + HEADER_LEN]u8,
    sdu: []const u8,
    cid: u16,
    conn_handle: u16,
    mtu: u16,
) FragmentIterator {
    // Prepend L2CAP header
    const total_len = HEADER_LEN + sdu.len;
    std.debug.assert(total_len <= sdu_buf.len);

    std.mem.writeInt(u16, sdu_buf[0..2], @intCast(sdu.len), .little);
    std.mem.writeInt(u16, sdu_buf[2..4], cid, .little);
    @memcpy(sdu_buf[HEADER_LEN..][0..sdu.len], sdu);

    return .{
        .sdu_with_header = sdu_buf[0..total_len],
        .conn_handle = conn_handle,
        .mtu = mtu,
        .offset = 0,
        .first = true,
        .buf = undefined,
    };
}

// ============================================================================
// Reassembly (RX: ACL fragments → SDU)
// ============================================================================

/// L2CAP reassembly buffer for a single connection.
///
/// Accumulates ACL fragments until a complete L2CAP SDU is ready.
/// One reassembler per connection handle.
pub const Reassembler = struct {
    /// Max SDU size: 512 (ATT MTU) + 4 (L2CAP header) + 4 (margin)
    const MAX_SDU_LEN = 520;

    buf: [MAX_SDU_LEN]u8 = undefined,
    len: usize = 0,
    expected_len: ?u16 = null,
    conn_handle: u16 = 0,

    /// Reset the reassembler state
    pub fn reset(self: *Reassembler) void {
        self.len = 0;
        self.expected_len = null;
    }

    /// Feed an ACL fragment (the data portion after ACL header).
    ///
    /// Returns a complete L2CAP SDU if reassembly is complete,
    /// or null if more fragments are needed.
    pub fn feed(self: *Reassembler, hdr: acl.AclHeader, data: []const u8) ?Sdu {
        switch (hdr.pb_flag) {
            .first_auto_flush, .first_non_auto_flush => {
                // Start of new SDU
                self.reset();
                self.conn_handle = hdr.conn_handle;

                // First fragment must contain at least the L2CAP header
                if (data.len < HEADER_LEN) {
                    self.reset();
                    return null;
                }

                // Read expected total L2CAP payload length
                const l2cap_len = std.mem.readInt(u16, data[0..2], .little);
                self.expected_len = l2cap_len;

                // Copy data
                const copy_len = @min(data.len, self.buf.len);
                @memcpy(self.buf[0..copy_len], data[0..copy_len]);
                self.len = copy_len;
            },
            .continuing => {
                // Continuation fragment
                if (self.expected_len == null) {
                    // No first fragment received — discard
                    return null;
                }

                const space = self.buf.len - self.len;
                const copy_len = @min(data.len, space);
                @memcpy(self.buf[self.len..][0..copy_len], data[0..copy_len]);
                self.len += copy_len;
            },
            .complete => {
                // Single-fragment SDU (unusual but valid)
                self.reset();
                self.conn_handle = hdr.conn_handle;
                if (data.len < HEADER_LEN) return null;

                const l2cap_len = std.mem.readInt(u16, data[0..2], .little);
                self.expected_len = l2cap_len;

                const copy_len = @min(data.len, self.buf.len);
                @memcpy(self.buf[0..copy_len], data[0..copy_len]);
                self.len = copy_len;
            },
        }

        // Check if reassembly is complete
        if (self.expected_len) |exp_len| {
            const total_needed = @as(usize, HEADER_LEN) + exp_len;
            if (self.len >= total_needed) {
                const l2cap_hdr = parseHeader(self.buf[0..HEADER_LEN]) orelse return null;
                const sdu = Sdu{
                    .conn_handle = self.conn_handle,
                    .cid = l2cap_hdr.cid,
                    .data = self.buf[HEADER_LEN..total_needed],
                };
                self.reset();
                return sdu;
            }
        }

        return null;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse L2CAP header" {
    const data = [_]u8{
        0x03, 0x00, // Length: 3
        0x04, 0x00, // CID: ATT (0x0004)
        0x02, 0x01, 0x00, // payload
    };

    const hdr = parseHeader(&data) orelse unreachable;
    try std.testing.expectEqual(@as(u16, 3), hdr.length);
    try std.testing.expectEqual(CID_ATT, hdr.cid);
}

test "reassemble single fragment" {
    var reasm = Reassembler{};

    // Single ACL packet containing complete L2CAP SDU
    const acl_data = [_]u8{
        0x03, 0x00, // L2CAP length: 3
        0x04, 0x00, // CID: ATT
        0xAA, 0xBB, 0xCC, // payload
    };

    const hdr = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = @intCast(acl_data.len),
    };

    const sdu = reasm.feed(hdr, &acl_data) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(@as(u16, 0x0040), sdu.conn_handle);
    try std.testing.expectEqual(CID_ATT, sdu.cid);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xAA, 0xBB, 0xCC }, sdu.data);
}

test "reassemble two fragments" {
    var reasm = Reassembler{};

    // Fragment 1: L2CAP header + partial data
    const frag1 = [_]u8{
        0x04, 0x00, // L2CAP length: 4
        0x04, 0x00, // CID: ATT
        0x01, 0x02, // partial payload
    };

    const hdr1 = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = @intCast(frag1.len),
    };

    // First fragment should not complete
    try std.testing.expect(reasm.feed(hdr1, &frag1) == null);

    // Fragment 2: remaining data
    const frag2 = [_]u8{ 0x03, 0x04 };
    const hdr2 = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = @intCast(frag2.len),
    };

    const sdu = reasm.feed(hdr2, &frag2) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(CID_ATT, sdu.cid);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03, 0x04 }, sdu.data);
}

test "reassemble three fragments (MTU 512 scenario)" {
    var reasm = Reassembler{};

    // Simulate a 512-byte ATT payload = 516 bytes with L2CAP header
    // Fragmented into 3 ACL packets with DLE 251:
    //   Frag 1: 251 bytes (L2CAP header + 247 bytes data) — first
    //   Frag 2: 251 bytes (251 bytes data) — continuing
    //   Frag 3: 14 bytes (remaining data) — continuing

    // Build the full L2CAP SDU: [len=512][CID=0x0004][512 bytes payload]
    var full_sdu: [516]u8 = undefined;
    std.mem.writeInt(u16, full_sdu[0..2], 512, .little); // L2CAP length
    std.mem.writeInt(u16, full_sdu[2..4], CID_ATT, .little); // CID
    for (0..512) |i| {
        full_sdu[4 + i] = @truncate(i); // pattern fill
    }

    // Fragment 1: first 251 bytes
    const hdr1 = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .first_auto_flush,
        .bc_flag = .point_to_point,
        .data_len = 251,
    };
    try std.testing.expect(reasm.feed(hdr1, full_sdu[0..251]) == null);

    // Fragment 2: next 251 bytes
    const hdr2 = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = 251,
    };
    try std.testing.expect(reasm.feed(hdr2, full_sdu[251..502]) == null);

    // Fragment 3: remaining 14 bytes → completes SDU
    const hdr3 = acl.AclHeader{
        .conn_handle = 0x0040,
        .pb_flag = .continuing,
        .bc_flag = .point_to_point,
        .data_len = 14,
    };
    const sdu = reasm.feed(hdr3, full_sdu[502..516]) orelse {
        return error.TestUnexpectedResult;
    };

    try std.testing.expectEqual(@as(u16, 0x0040), sdu.conn_handle);
    try std.testing.expectEqual(CID_ATT, sdu.cid);
    try std.testing.expectEqual(@as(usize, 512), sdu.data.len);
    // Verify first and last payload bytes
    try std.testing.expectEqual(@as(u8, 0), sdu.data[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), sdu.data[255]);
}

test "fragment iterator single fragment" {
    var sdu_buf: [acl.LE_MAX_DATA_LEN + HEADER_LEN]u8 = undefined;
    const payload_data = [_]u8{ 0x01, 0x02, 0x03 };
    var iter = fragmentIterator(&sdu_buf, &payload_data, CID_ATT, 0x0040, 27);

    // Should produce exactly one fragment (3 + 4 header = 7 < 27 MTU)
    const frag = iter.next() orelse unreachable;
    try std.testing.expectEqual(@as(u8, 0x02), frag[0]); // ACL indicator

    // No more fragments
    try std.testing.expect(iter.next() == null);
}
