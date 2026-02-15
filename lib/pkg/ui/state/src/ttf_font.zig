//! TtfFont — Runtime TrueType font renderer via stb_truetype
//!
//! Renders glyphs on demand from TTF font data loaded via VFS.
//! Supports any Unicode codepoint at any size.
//!
//! Usage:
//! ```zig
//! var font = TtfFont.init(ttf_data, 24.0) orelse return;
//! const glyph = font.getGlyph('中') orelse continue;
//! // glyph.bitmap: []const u8 (8-bit alpha), glyph.w, glyph.h, glyph.x_off, glyph.y_off
//! ```

const c = @cImport(@cInclude("stb_truetype.h"));

/// Rendered glyph bitmap + metrics
pub const Glyph = struct {
    /// 8-bit alpha bitmap (w * h bytes), row-major
    bitmap: [*]const u8,
    w: u16,
    h: u16,
    /// Offset from cursor position to top-left of bitmap
    x_off: i16,
    y_off: i16,
    /// How much to advance cursor after this glyph
    advance: u16,
};

/// Maximum cached glyphs
const CACHE_SIZE = 128;

const CacheEntry = struct {
    codepoint: u21 = 0,
    size_x10: u16 = 0, // font size * 10 (to distinguish sizes)
    bitmap_buf: [48 * 48]u8 = undefined, // max glyph 48x48
    glyph: Glyph = undefined,
    valid: bool = false,
};

/// TrueType font renderer.
///
/// Holds a reference to TTF data (must outlive the TtfFont).
/// Renders glyphs lazily with an internal cache.
pub const TtfFont = struct {
    const Self = @This();

    info: c.stbtt_fontinfo,
    scale: f32,
    ascent: i32,
    descent: i32,
    line_gap: i32,
    size: f32,
    cache: [CACHE_SIZE]CacheEntry,

    /// Initialize from raw TTF data at a given pixel size.
    /// Returns null if the TTF data is invalid.
    pub fn init(ttf_data: []const u8, pixel_size: f32) ?Self {
        var self: Self = undefined;
        self.size = pixel_size;
        @memset(&self.cache, CacheEntry{});

        if (c.stbtt_InitFont(&self.info, ttf_data.ptr, 0) == 0) {
            return null;
        }

        self.scale = c.stbtt_ScaleForPixelHeight(&self.info, pixel_size);

        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(&self.info, &asc, &desc, &gap);
        self.ascent = @intFromFloat(@as(f32, @floatFromInt(asc)) * self.scale);
        self.descent = @intFromFloat(@as(f32, @floatFromInt(desc)) * self.scale);
        self.line_gap = @intFromFloat(@as(f32, @floatFromInt(gap)) * self.scale);

        return self;
    }

    /// Line height in pixels
    pub fn lineHeight(self: *const Self) u16 {
        return @intCast(self.ascent - self.descent + self.line_gap);
    }

    /// Get a rendered glyph for a codepoint.
    /// Returns cached result if available, otherwise renders and caches.
    pub fn getGlyph(self: *Self, codepoint: u21) ?Glyph {
        const size_x10: u16 = @intFromFloat(self.size * 10);

        // Check cache
        const slot = @as(usize, codepoint) % CACHE_SIZE;
        if (self.cache[slot].valid and
            self.cache[slot].codepoint == codepoint and
            self.cache[slot].size_x10 == size_x10)
        {
            return self.cache[slot].glyph;
        }

        // Render
        var w: c_int = 0;
        var h: c_int = 0;
        var x_off: c_int = 0;
        var y_off: c_int = 0;

        const bitmap = c.stbtt_GetCodepointBitmap(
            &self.info,
            0,
            self.scale,
            @intCast(codepoint),
            &w,
            &h,
            &x_off,
            &y_off,
        );
        if (bitmap == null or w <= 0 or h <= 0) return null;
        defer c.stbtt_FreeBitmap(bitmap, null);

        // Get advance width
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(&self.info, @intCast(codepoint), &adv, &lsb);
        const advance: u16 = @intFromFloat(@as(f32, @floatFromInt(adv)) * self.scale);

        const uw: u16 = @intCast(w);
        const uh: u16 = @intCast(h);
        const copy_size = @as(usize, uw) * @as(usize, uh);

        // Cache (overwrite slot)
        if (copy_size <= self.cache[slot].bitmap_buf.len) {
            @memcpy(self.cache[slot].bitmap_buf[0..copy_size], bitmap[0..copy_size]);
            self.cache[slot].glyph = .{
                .bitmap = &self.cache[slot].bitmap_buf,
                .w = uw,
                .h = uh,
                .x_off = @intCast(x_off),
                .y_off = @intCast(y_off),
                .advance = advance,
            };
            self.cache[slot].codepoint = codepoint;
            self.cache[slot].size_x10 = size_x10;
            self.cache[slot].valid = true;
            return self.cache[slot].glyph;
        }

        // Glyph too large for cache — return without caching
        return null;
    }

    /// Measure text width in pixels
    pub fn textWidth(self: *Self, text: []const u8) u16 {
        const font_mod = @import("font.zig");
        var width: u16 = 0;
        var i: usize = 0;
        while (i < text.len) {
            const decoded = font_mod.decodeUtf8(text[i..]);
            i += decoded.len;
            if (decoded.codepoint) |cp| {
                if (self.getGlyph(cp)) |g| {
                    width += g.advance;
                }
            }
        }
        return width;
    }
};
