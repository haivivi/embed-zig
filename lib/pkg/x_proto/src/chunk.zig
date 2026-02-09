//! chunk — BLE X-Protocol chunk encoding and bitmask utilities
//!
//! Provides chunk header encode/decode, control message handling,
//! and bitmask operations for the READ_X / WRITE_X protocols.
//!
//! ## Chunk Header Format (3 bytes)
//!
//! ```
//! Byte 0:    [total_hi 8bit]
//! Byte 1:    [total_lo 4bit][seq_hi 4bit]
//! Byte 2:    [seq_lo 8bit]
//!
//! total = 12 bit → max 4095 chunks
//! seq   = 12 bit → 1-based (1 to total)
//! ```
//!
//! ## Control Messages
//!
//! | Message     | Format              | Meaning                    |
//! |-------------|---------------------|----------------------------|
//! | Start Magic | `0xFFFF0001` (4B)   | READ_X: begin transfer     |
//! | ACK         | `0xFFFF` (2B)       | All chunks received        |
//! | Loss List   | `[seq_be16]...`     | Missing seqs, request retry|

const std = @import("std");

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of chunks supported (12-bit field).
pub const max_chunks: u16 = 4095;

/// Chunk header size in bytes.
pub const header_size: usize = 3;

/// ATT protocol overhead (for GATT write/notify).
pub const att_overhead: usize = 3;

/// Total overhead per chunk: header + ATT.
pub const chunk_overhead: usize = header_size + att_overhead;

/// Maximum BLE ATT_MTU (BLE 5.2).
pub const max_mtu: usize = 517;

/// Maximum bitmask size in bytes (ceil(4095 / 8)).
pub const max_mask_bytes: usize = (max_chunks + 7) / 8;

/// Start magic for READ_X protocol (0xFFFF0001, big-endian).
pub const start_magic = [4]u8{ 0xFF, 0xFF, 0x00, 0x01 };

/// ACK signal (0xFFFF, big-endian).
pub const ack_signal = [2]u8{ 0xFF, 0xFF };

// ============================================================================
// Chunk Header
// ============================================================================

/// Decoded chunk header.
pub const Header = struct {
    /// Total number of chunks (1..4095).
    total: u16,
    /// Sequence number, 1-based (1..total).
    seq: u16,

    /// Encode header into 3 bytes.
    pub fn encode(self: Header) [header_size]u8 {
        return .{
            @intCast((self.total >> 4) & 0xFF),
            @intCast(((self.total & 0xF) << 4) | ((self.seq >> 8) & 0xF)),
            @intCast(self.seq & 0xFF),
        };
    }

    /// Decode header from 3 bytes.
    pub fn decode(bytes: *const [header_size]u8) Header {
        return .{
            .total = @as(u16, bytes[0]) << 4 | @as(u16, bytes[1]) >> 4,
            .seq = @as(u16, bytes[1] & 0xF) << 8 | @as(u16, bytes[2]),
        };
    }

    /// Validate header fields.
    pub fn validate(self: Header) error{InvalidHeader}!void {
        if (self.total == 0 or self.total > max_chunks) return error.InvalidHeader;
        if (self.seq == 0 or self.seq > self.total) return error.InvalidHeader;
    }
};

// ============================================================================
// Control Messages
// ============================================================================

/// Check if data is the READ_X start magic (0xFFFF0001).
pub fn isStartMagic(data: []const u8) bool {
    return data.len >= 4 and std.mem.eql(u8, data[0..4], &start_magic);
}

/// Check if data is an ACK signal (0xFFFF).
pub fn isAck(data: []const u8) bool {
    return data.len >= 2 and data[0] == 0xFF and data[1] == 0xFF;
}

/// Encode a loss list into a buffer. Each seq is big-endian u16.
/// Returns the written slice.
pub fn encodeLossList(seqs: []const u16, buf: []u8) []u8 {
    var offset: usize = 0;
    for (seqs) |seq| {
        if (offset + 2 > buf.len) break;
        buf[offset] = @intCast((seq >> 8) & 0xFF);
        buf[offset + 1] = @intCast(seq & 0xFF);
        offset += 2;
    }
    return buf[0..offset];
}

/// Decode a loss list from received data. Returns number of seqs decoded.
pub fn decodeLossList(data: []const u8, out: []u16) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (offset + 2 <= data.len and count < out.len) {
        out[count] = @as(u16, data[offset]) << 8 | @as(u16, data[offset + 1]);
        count += 1;
        offset += 2;
    }
    return count;
}

// ============================================================================
// Bitmask Operations
// ============================================================================

/// Operations on a chunk tracking bitmask.
///
/// Bit layout: bit index = seq - 1.
/// Bit 0 of byte 0 = seq 1, bit 7 of byte 0 = seq 8, etc.
pub const Bitmask = struct {
    /// Required buffer size for `total` chunks.
    pub fn requiredBytes(total: u16) usize {
        return (@as(usize, total) + 7) / 8;
    }

    /// Clear all bits (no chunks tracked).
    pub fn initClear(buf: []u8, total: u16) void {
        @memset(buf[0..requiredBytes(total)], 0);
    }

    /// Set all valid bits (all chunks pending).
    /// Unused high bits in last byte are cleared.
    pub fn initAllSet(buf: []u8, total: u16) void {
        const len = requiredBytes(total);
        @memset(buf[0..len], 0xFF);
        const remainder: u3 = @intCast(total % 8);
        if (remainder != 0) {
            buf[len - 1] = (@as(u8, 1) << remainder) - 1;
        }
    }

    /// Set bit for a chunk seq (1-based).
    pub fn set(buf: []u8, seq: u16) void {
        const idx = seq - 1;
        buf[idx / 8] |= @as(u8, 1) << @intCast(idx % 8);
    }

    /// Clear bit for a chunk seq (1-based).
    pub fn clear(buf: []u8, seq: u16) void {
        const idx = seq - 1;
        buf[idx / 8] &= ~(@as(u8, 1) << @intCast(idx % 8));
    }

    /// Check if bit is set for a chunk seq (1-based).
    pub fn isSet(buf: []const u8, seq: u16) bool {
        const idx = seq - 1;
        return (buf[idx / 8] & (@as(u8, 1) << @intCast(idx % 8))) != 0;
    }

    /// Check if all valid bits are set (transfer complete).
    pub fn isComplete(buf: []const u8, total: u16) bool {
        const full_bytes: usize = @as(usize, total) / 8;
        for (buf[0..full_bytes]) |b| {
            if (b != 0xFF) return false;
        }
        const remainder: u3 = @intCast(total % 8);
        if (remainder != 0) {
            const expected: u8 = (@as(u8, 1) << remainder) - 1;
            if ((buf[full_bytes] & expected) != expected) return false;
        }
        return true;
    }

    /// Collect missing seq numbers (bits NOT set). Returns count written to `out`.
    pub fn collectMissing(buf: []const u8, total: u16, out: []u16) usize {
        var count: usize = 0;
        var seq: u16 = 1;
        while (seq <= total and count < out.len) : (seq += 1) {
            if (!isSet(buf, seq)) {
                out[count] = seq;
                count += 1;
            }
        }
        return count;
    }
};

// ============================================================================
// Helpers
// ============================================================================

/// Max data payload per chunk: MTU - 3 (ATT) - 3 (header).
pub fn dataChunkSize(mtu: u16) usize {
    if (mtu <= chunk_overhead) return 1;
    return @as(usize, mtu) - chunk_overhead;
}

/// Number of chunks needed for `data_len` bytes at given MTU.
pub fn chunksNeeded(data_len: usize, mtu: u16) usize {
    const dcs = dataChunkSize(mtu);
    if (data_len == 0) return 0;
    return (data_len + dcs - 1) / dcs;
}

// ============================================================================
// Tests
// ============================================================================

test "Header encode/decode roundtrip" {
    const cases = [_]Header{
        .{ .total = 1, .seq = 1 },
        .{ .total = 100, .seq = 50 },
        .{ .total = 4095, .seq = 4095 },
        .{ .total = 4095, .seq = 1 },
        .{ .total = 256, .seq = 128 },
        .{ .total = 0xABC, .seq = 0x123 },
    };
    for (cases) |h| {
        const encoded = h.encode();
        const decoded = Header.decode(&encoded);
        try std.testing.expectEqual(h.total, decoded.total);
        try std.testing.expectEqual(h.seq, decoded.seq);
    }
}

test "Header validate" {
    try (Header{ .total = 1, .seq = 1 }).validate();
    try (Header{ .total = 4095, .seq = 4095 }).validate();
    try (Header{ .total = 100, .seq = 100 }).validate();

    try std.testing.expectError(error.InvalidHeader, (Header{ .total = 0, .seq = 1 }).validate());
    try std.testing.expectError(error.InvalidHeader, (Header{ .total = 1, .seq = 0 }).validate());
    try std.testing.expectError(error.InvalidHeader, (Header{ .total = 1, .seq = 2 }).validate());
    try std.testing.expectError(error.InvalidHeader, (Header{ .total = 4096, .seq = 1 }).validate());
}

test "Control message detection" {
    try std.testing.expect(isStartMagic(&start_magic));
    try std.testing.expect(!isStartMagic(&[_]u8{ 0xFF, 0xFF, 0x00, 0x02 }));
    try std.testing.expect(!isStartMagic(&[_]u8{ 0xFF, 0xFF }));

    try std.testing.expect(isAck(&ack_signal));
    try std.testing.expect(isAck(&[_]u8{ 0xFF, 0xFF, 0x00 })); // extra bytes ok
    try std.testing.expect(!isAck(&[_]u8{0xFF})); // too short
}

test "Loss list encode/decode roundtrip" {
    const seqs = [_]u16{ 1, 42, 4095 };
    var buf: [6]u8 = undefined;
    const encoded = encodeLossList(&seqs, &buf);
    try std.testing.expectEqual(@as(usize, 6), encoded.len);

    var decoded: [3]u16 = undefined;
    const count = decodeLossList(encoded, &decoded);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(u16, 1), decoded[0]);
    try std.testing.expectEqual(@as(u16, 42), decoded[1]);
    try std.testing.expectEqual(@as(u16, 4095), decoded[2]);
}

test "Loss list truncation" {
    const seqs = [_]u16{ 1, 2, 3 };
    var buf: [4]u8 = undefined; // only room for 2 seqs
    const encoded = encodeLossList(&seqs, &buf);
    try std.testing.expectEqual(@as(usize, 4), encoded.len);

    var decoded: [2]u16 = undefined;
    const count = decodeLossList(encoded, &decoded);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 1), decoded[0]);
    try std.testing.expectEqual(@as(u16, 2), decoded[1]);
}

test "Bitmask basic operations" {
    var buf: [2]u8 = undefined;
    Bitmask.initClear(&buf, 10);

    try std.testing.expect(!Bitmask.isSet(&buf, 1));
    try std.testing.expect(!Bitmask.isSet(&buf, 10));

    Bitmask.set(&buf, 1);
    try std.testing.expect(Bitmask.isSet(&buf, 1));
    try std.testing.expect(!Bitmask.isSet(&buf, 2));

    Bitmask.set(&buf, 10);
    try std.testing.expect(Bitmask.isSet(&buf, 10));

    Bitmask.clear(&buf, 1);
    try std.testing.expect(!Bitmask.isSet(&buf, 1));
    try std.testing.expect(Bitmask.isSet(&buf, 10));
}

test "Bitmask initAllSet" {
    // 10 chunks → 2 bytes, bits 0-9 set
    var buf: [2]u8 = undefined;
    Bitmask.initAllSet(&buf, 10);
    try std.testing.expectEqual(@as(u8, 0xFF), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[1]);

    // 8 chunks → 1 byte, all bits set
    var buf2: [1]u8 = undefined;
    Bitmask.initAllSet(&buf2, 8);
    try std.testing.expectEqual(@as(u8, 0xFF), buf2[0]);

    // 1 chunk → 1 byte, bit 0 only
    var buf3: [1]u8 = undefined;
    Bitmask.initAllSet(&buf3, 1);
    try std.testing.expectEqual(@as(u8, 0x01), buf3[0]);

    // 16 chunks → 2 bytes, all set
    var buf4: [2]u8 = undefined;
    Bitmask.initAllSet(&buf4, 16);
    try std.testing.expectEqual(@as(u8, 0xFF), buf4[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), buf4[1]);
}

test "Bitmask isComplete" {
    var buf: [2]u8 = undefined;
    Bitmask.initClear(&buf, 10);
    try std.testing.expect(!Bitmask.isComplete(&buf, 10));

    // Set all 10 bits
    for (1..11) |seq| {
        Bitmask.set(&buf, @intCast(seq));
    }
    try std.testing.expect(Bitmask.isComplete(&buf, 10));

    // Clear one
    Bitmask.clear(&buf, 5);
    try std.testing.expect(!Bitmask.isComplete(&buf, 10));

    // Edge case: 8 chunks (exact byte boundary)
    var buf2: [1]u8 = undefined;
    Bitmask.initClear(&buf2, 8);
    for (1..9) |seq| {
        Bitmask.set(&buf2, @intCast(seq));
    }
    try std.testing.expect(Bitmask.isComplete(&buf2, 8));
}

test "Bitmask collectMissing" {
    var buf: [2]u8 = undefined;
    Bitmask.initClear(&buf, 10);

    // Set all except 3, 7
    for (1..11) |seq| {
        if (seq != 3 and seq != 7) {
            Bitmask.set(&buf, @intCast(seq));
        }
    }

    var missing: [10]u16 = undefined;
    const count = Bitmask.collectMissing(&buf, 10, &missing);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 3), missing[0]);
    try std.testing.expectEqual(@as(u16, 7), missing[1]);
}

test "Bitmask collectMissing with limited output" {
    var buf: [1]u8 = undefined;
    Bitmask.initClear(&buf, 5); // all missing

    var missing: [2]u16 = undefined; // only room for 2
    const count = Bitmask.collectMissing(&buf, 5, &missing);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u16, 1), missing[0]);
    try std.testing.expectEqual(@as(u16, 2), missing[1]);
}

test "dataChunkSize" {
    try std.testing.expectEqual(@as(usize, 241), dataChunkSize(247));
    try std.testing.expectEqual(@as(usize, 24), dataChunkSize(30));
    try std.testing.expectEqual(@as(usize, 1), dataChunkSize(7));
    try std.testing.expectEqual(@as(usize, 1), dataChunkSize(6)); // at overhead
    try std.testing.expectEqual(@as(usize, 1), dataChunkSize(1)); // below overhead
}

test "chunksNeeded" {
    // MTU=247, dcs=241
    try std.testing.expectEqual(@as(usize, 5), chunksNeeded(1000, 247));
    try std.testing.expectEqual(@as(usize, 4), chunksNeeded(964, 247)); // 4*241=964
    try std.testing.expectEqual(@as(usize, 1), chunksNeeded(1, 247));
    try std.testing.expectEqual(@as(usize, 0), chunksNeeded(0, 247));

    // MTU=30, dcs=24
    try std.testing.expectEqual(@as(usize, 3), chunksNeeded(56, 30)); // ceil(56/24)=3
    try std.testing.expectEqual(@as(usize, 2), chunksNeeded(48, 30)); // exact
    try std.testing.expectEqual(@as(usize, 2), chunksNeeded(25, 30)); // just over 1
}
