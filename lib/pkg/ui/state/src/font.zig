//! Bitmap Font — Dynamic Font System
//!
//! Supports any character set (ASCII, CJK, etc.) via a lookup function
//! pointer that maps Unicode codepoints to glyph indices.
//!
//! Font data is external — can be @embedFile'd at compile time,
//! loaded from flash, or generated at runtime. The BitmapFont struct
//! just references the data; it owns nothing.
//!
//! Glyph format: 1 bit per pixel, row-major, MSB first.
//! Each row is ceil(glyph_w / 8) bytes. Total per glyph:
//!   ceil(glyph_w / 8) * glyph_h bytes.

/// Bitmap font descriptor.
///
/// All fields are set by the caller — the font system imposes no
/// constraints on character set, size, or data source.
pub const BitmapFont = struct {
    /// Glyph width in pixels (fixed-width; all glyphs same width).
    glyph_w: u8,
    /// Glyph height in pixels.
    glyph_h: u8,
    /// Raw bitmap data — packed 1bpp glyphs, contiguous.
    data: []const u8,
    /// Maps a Unicode codepoint to a glyph index in `data`.
    /// Returns null if the codepoint is not in this font.
    lookup: *const fn (u21) ?u32,

    /// Bytes per glyph row.
    pub fn bytesPerRow(self: *const BitmapFont) usize {
        return (@as(usize, self.glyph_w) + 7) / 8;
    }

    /// Total bytes per glyph.
    pub fn glyphSize(self: *const BitmapFont) usize {
        return self.bytesPerRow() * @as(usize, self.glyph_h);
    }

    /// Get the bitmap data for a given codepoint.
    /// Returns null if the codepoint is not in this font.
    pub fn getGlyph(self: *const BitmapFont, codepoint: u21) ?[]const u8 {
        const idx = self.lookup(codepoint) orelse return null;
        const size = self.glyphSize();
        const start = @as(usize, idx) * size;
        if (start + size > self.data.len) return null;
        return self.data[start..][0..size];
    }

    /// Measure text width in pixels. Input is UTF-8.
    /// Unknown codepoints are skipped (0 width).
    pub fn textWidth(self: *const BitmapFont, text: []const u8) u16 {
        var width: u16 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const decoded = decodeUtf8(text[i..]);
            i += decoded.len;
            if (decoded.codepoint) |cp| {
                if (self.lookup(cp) != null) {
                    width += self.glyph_w;
                }
            }
        }
        return width;
    }
};

/// Create a lookup function for a contiguous ASCII range.
///
/// Example: `asciiLookup(32, 95)` covers space (0x20) through tilde (0x7E).
pub fn asciiLookup(comptime first: u8, comptime count: u16) *const fn (u21) ?u32 {
    const S = struct {
        fn lookup(cp: u21) ?u32 {
            if (cp < first or cp >= @as(u21, first) + count) return null;
            return @intCast(cp - first);
        }
    };
    return &S.lookup;
}

// ============================================================================
// UTF-8 Decoding
// ============================================================================

/// Result of decoding one UTF-8 character.
pub const Utf8Result = struct {
    codepoint: ?u21,
    len: usize,
};

/// Decode one UTF-8 codepoint from the start of `bytes`.
///
/// Returns the codepoint and the number of bytes consumed.
/// On invalid UTF-8, returns null codepoint and advances 1 byte.
pub fn decodeUtf8(bytes: []const u8) Utf8Result {
    if (bytes.len == 0) return .{ .codepoint = null, .len = 0 };

    const b0 = bytes[0];

    // ASCII
    if (b0 < 0x80) {
        return .{ .codepoint = b0, .len = 1 };
    }

    // Determine sequence length
    const seq_len: usize, const initial: u21 = if (b0 & 0xE0 == 0xC0)
        .{ 2, b0 & 0x1F }
    else if (b0 & 0xF0 == 0xE0)
        .{ 3, b0 & 0x0F }
    else if (b0 & 0xF8 == 0xF0)
        .{ 4, b0 & 0x07 }
    else
        return .{ .codepoint = null, .len = 1 }; // invalid lead byte

    if (bytes.len < seq_len) return .{ .codepoint = null, .len = 1 };

    var cp: u21 = initial;
    for (1..seq_len) |i| {
        const b = bytes[i];
        if (b & 0xC0 != 0x80) return .{ .codepoint = null, .len = 1 };
        cp = (cp << 6) | (b & 0x3F);
    }

    return .{ .codepoint = cp, .len = seq_len };
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

// Test font: 4x4 pixels, 3 glyphs (A=0, B=1, C=2)
// Glyph 'A' (0x41): simple pattern
//   .##.    = 0x60
//   #..#    = 0x90
//   ####    = 0xF0
//   #..#    = 0x90
//
// Glyph 'B' (0x42):
//   ###.    = 0xE0
//   #..#    = 0x90
//   ###.    = 0xE0
//   ###.    = 0xE0
//
// Glyph 'C' (0x43):
//   .##.    = 0x60
//   #...    = 0x80
//   #...    = 0x80
//   .##.    = 0x60
const test_font_data = [_]u8{
    // A
    0x60, 0x90, 0xF0, 0x90,
    // B
    0xE0, 0x90, 0xE0, 0xE0,
    // C
    0x60, 0x80, 0x80, 0x60,
};

fn testLookup(cp: u21) ?u32 {
    if (cp >= 'A' and cp <= 'C') return @intCast(cp - 'A');
    return null;
}

const test_font = BitmapFont{
    .glyph_w = 4,
    .glyph_h = 4,
    .data = &test_font_data,
    .lookup = &testLookup,
};

test "BitmapFont.glyphSize" {
    try testing.expectEqual(@as(usize, 4), test_font.glyphSize()); // 4x4, 1 byte/row, 4 rows
}

test "BitmapFont.getGlyph returns correct data" {
    const glyph_a = test_font.getGlyph('A').?;
    try testing.expectEqual(@as(usize, 4), glyph_a.len);
    try testing.expectEqual(@as(u8, 0x60), glyph_a[0]);
    try testing.expectEqual(@as(u8, 0x90), glyph_a[1]);

    const glyph_c = test_font.getGlyph('C').?;
    try testing.expectEqual(@as(u8, 0x60), glyph_c[0]);
    try testing.expectEqual(@as(u8, 0x80), glyph_c[1]);
}

test "BitmapFont.getGlyph returns null for unknown" {
    try testing.expectEqual(@as(?[]const u8, null), test_font.getGlyph('Z'));
    try testing.expectEqual(@as(?[]const u8, null), test_font.getGlyph(0x4E2D)); // 中
}

test "BitmapFont.textWidth" {
    try testing.expectEqual(@as(u16, 12), test_font.textWidth("ABC"));
    try testing.expectEqual(@as(u16, 4), test_font.textWidth("A"));
    try testing.expectEqual(@as(u16, 4), test_font.textWidth("AZ")); // Z unknown → skipped, only A counted
    try testing.expectEqual(@as(u16, 0), test_font.textWidth(""));
    try testing.expectEqual(@as(u16, 0), test_font.textWidth("XYZ")); // all unknown
}

test "asciiLookup: printable ASCII" {
    const lookup = asciiLookup(32, 95);
    try testing.expectEqual(@as(?u32, 0), lookup(' ')); // 32
    try testing.expectEqual(@as(?u32, 33), lookup('A')); // 65
    try testing.expectEqual(@as(?u32, 94), lookup('~')); // 126
    try testing.expectEqual(@as(?u32, null), lookup(0x1F)); // below range
    try testing.expectEqual(@as(?u32, null), lookup(0x7F)); // above range
}

test "decodeUtf8: ASCII" {
    const r = decodeUtf8("Hello");
    try testing.expectEqual(@as(?u21, 'H'), r.codepoint);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "decodeUtf8: 2-byte (Latin)" {
    const r = decodeUtf8("\xC3\xA9"); // é = U+00E9
    try testing.expectEqual(@as(?u21, 0xE9), r.codepoint);
    try testing.expectEqual(@as(usize, 2), r.len);
}

test "decodeUtf8: 3-byte (CJK)" {
    const r = decodeUtf8("\xE4\xB8\xAD"); // 中 = U+4E2D
    try testing.expectEqual(@as(?u21, 0x4E2D), r.codepoint);
    try testing.expectEqual(@as(usize, 3), r.len);
}

test "decodeUtf8: 4-byte (emoji)" {
    const r = decodeUtf8("\xF0\x9F\x98\x80"); // 😀 = U+1F600
    try testing.expectEqual(@as(?u21, 0x1F600), r.codepoint);
    try testing.expectEqual(@as(usize, 4), r.len);
}

test "decodeUtf8: invalid byte" {
    const r = decodeUtf8("\xFF\x00");
    try testing.expectEqual(@as(?u21, null), r.codepoint);
    try testing.expectEqual(@as(usize, 1), r.len);
}

test "decodeUtf8: empty" {
    const r = decodeUtf8("");
    try testing.expectEqual(@as(?u21, null), r.codepoint);
    try testing.expectEqual(@as(usize, 0), r.len);
}
