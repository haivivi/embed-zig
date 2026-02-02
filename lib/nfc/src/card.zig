//! NFC Card Type Definitions
//!
//! Common card structures shared by all NFC reader drivers.
//! Based on ISO14443A/B specifications.

const std = @import("std");

/// ISO14443A Card (Mifare, NTAG, etc.)
pub const TypeACard = struct {
    /// Answer To Request A (2 bytes)
    /// Bits 7:6 of atqa[0] indicate UID size:
    /// - 0b00: Single size (4 bytes)
    /// - 0b01: Double size (7 bytes)
    /// - 0b10: Triple size (10 bytes)
    atqa: [2]u8 = .{ 0, 0 },

    /// Cascade level (1, 2, or 3)
    cascade_level: u2 = 0,

    /// UID bytes (up to 10 bytes for triple size)
    uid: [10]u8 = .{0} ** 10,

    /// Actual UID length (4, 7, or 10)
    uid_len: u4 = 0,

    /// Select Acknowledge (one per cascade level)
    sak: [3]u8 = .{ 0, 0, 0 },

    /// Get UID slice
    pub fn getUid(self: *const TypeACard) []const u8 {
        return self.uid[0..self.uid_len];
    }

    /// Check if card supports ISO14443-4 (based on SAK)
    pub fn supportsIso14443_4(self: *const TypeACard) bool {
        const final_sak = self.sak[self.cascade_level - 1];
        return (final_sak & 0x20) != 0;
    }

    /// Check if this is a Mifare Classic card
    pub fn isMifareClassic(self: *const TypeACard) bool {
        const final_sak = self.sak[self.cascade_level - 1];
        return (final_sak & 0x18) == 0x08;
    }

    /// Check if this is a Mifare Ultralight/NTAG card
    pub fn isMifareUltralight(self: *const TypeACard) bool {
        const final_sak = self.sak[self.cascade_level - 1];
        return final_sak == 0x00;
    }

    /// Format UID as hex string
    pub fn formatUid(self: *const TypeACard, buf: []u8) []const u8 {
        const uid_slice = self.getUid();
        var written: usize = 0;
        for (uid_slice) |byte| {
            if (written + 2 > buf.len) break;
            _ = std.fmt.bufPrint(buf[written..], "{X:0>2}", .{byte}) catch break;
            written += 2;
        }
        return buf[0..written];
    }
};

/// ISO14443B Card
pub const TypeBCard = struct {
    /// Answer To Request B (12 bytes)
    atqb: [12]u8 = .{0} ** 12,

    /// Pseudo-Unique PICC Identifier (4 bytes, from ATQB[1..5])
    pupi: [4]u8 = .{ 0, 0, 0, 0 },

    /// Application Data (4 bytes, from ATQB[5..9])
    application_data: [4]u8 = .{ 0, 0, 0, 0 },

    /// Protocol Info (3 bytes, from ATQB[9..12])
    protocol_info: [3]u8 = .{ 0, 0, 0 },

    /// ATTRIB response
    attrib: [10]u8 = .{0} ** 10,

    /// ATTRIB response length
    attrib_len: u4 = 0,

    /// Get PUPI as identifier
    pub fn getPupi(self: *const TypeBCard) []const u8 {
        return &self.pupi;
    }

    /// Parse ATQB response
    pub fn parseAtqb(self: *TypeBCard) void {
        // ATQB format: [0x50] [PUPI:4] [APP_DATA:4] [PROTOCOL_INFO:3]
        @memcpy(&self.pupi, self.atqb[1..5]);
        @memcpy(&self.application_data, self.atqb[5..9]);
        @memcpy(&self.protocol_info, self.atqb[9..12]);
    }

    /// Get maximum frame size from protocol info
    pub fn getMaxFrameSize(self: *const TypeBCard) u16 {
        const fsci = self.protocol_info[1] >> 4;
        return switch (fsci) {
            0 => 16,
            1 => 24,
            2 => 32,
            3 => 40,
            4 => 48,
            5 => 64,
            6 => 96,
            7 => 128,
            8 => 256,
            else => 256,
        };
    }
};

/// NFC card type enumeration
pub const CardType = enum {
    none,
    type_a,
    type_b,
    type_f, // FeliCa
};

/// Generic card info
pub const CardInfo = union(CardType) {
    none: void,
    type_a: TypeACard,
    type_b: TypeBCard,
    type_f: void, // TODO: FeliCa support
};

// =========== Tests ===========

test "TypeACard UID handling" {
    var card = TypeACard{
        .uid = .{ 0x04, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0, 0, 0 },
        .uid_len = 7,
        .cascade_level = 2,
        .sak = .{ 0x04, 0x00, 0 },
    };

    const uid = card.getUid();
    try std.testing.expectEqual(@as(usize, 7), uid.len);
    try std.testing.expectEqual(@as(u8, 0x04), uid[0]);

    try std.testing.expect(card.isMifareUltralight());
    try std.testing.expect(!card.isMifareClassic());

    var buf: [20]u8 = undefined;
    const hex = card.formatUid(&buf);
    try std.testing.expectEqualStrings("04112233445566", hex);
}

test "TypeBCard ATQB parsing" {
    var card = TypeBCard{
        .atqb = .{ 0x50, 0x01, 0x02, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD, 0x81, 0x81, 0x00 },
    };

    card.parseAtqb();

    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0x04 }, &card.pupi);
    try std.testing.expectEqualSlices(u8, &.{ 0xAA, 0xBB, 0xCC, 0xDD }, &card.application_data);
}
