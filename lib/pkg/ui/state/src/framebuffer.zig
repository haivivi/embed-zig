//! Framebuffer — Pixel Drawing Primitives
//!
//! Comptime-generic framebuffer with built-in dirty rect tracking.
//! Resolution and color format are fixed at compile time for zero
//! runtime overhead (no vtable, no dynamic dispatch).
//!
//! Every drawing operation automatically marks the affected region
//! as dirty. At flush time, use getDirtyRects() + getRegion() to
//! send only changed pixels to the display via SPI LCD.
//!
//! Data flow:
//!   fb.fillRect(...)  →  writes pixels to buf  →  marks dirty rect
//!   fb.getDirtyRects() → returns dirty regions
//!   fb.getRegion(rect, out) → copies sub-rect pixels (no stride) for SPI flush
//!   fb.clearDirty() → reset after flush

const dirty_mod = @import("dirty.zig");
const DirtyTracker = dirty_mod.DirtyTracker;
const Rect = dirty_mod.Rect;
const font_mod = @import("font.zig");
const BitmapFont = font_mod.BitmapFont;
const image_mod = @import("image.zig");
const Image = image_mod.Image;
pub const TtfFont = @import("ttf_font.zig").TtfFont;

/// Color format for the framebuffer.
pub const ColorFormat = enum {
    rgb565,
    rgb888,
    argb8888,

    /// The Zig type used to store one pixel.
    pub fn ColorType(comptime self: ColorFormat) type {
        return switch (self) {
            .rgb565 => u16,
            .rgb888 => u24,
            .argb8888 => u32,
        };
    }

    /// Bytes per pixel.
    pub fn bpp(comptime self: ColorFormat) u8 {
        return switch (self) {
            .rgb565 => 2,
            .rgb888 => 3,
            .argb8888 => 4,
        };
    }
};

/// Maximum number of dirty rects tracked per frame.
const DIRTY_MAX: u8 = 16;

/// Create a framebuffer with compile-time fixed resolution and color format.
///
/// Example:
/// ```
/// const FB = Framebuffer(240, 240, .rgb565);
/// var fb = FB.init(0x0000); // black fill
/// fb.fillRect(10, 10, 50, 50, 0xF800); // red square
/// ```
pub fn Framebuffer(comptime W: u16, comptime H: u16, comptime fmt: ColorFormat) type {
    const Color = fmt.ColorType();
    const BufLen = @as(usize, W) * @as(usize, H);

    return struct {
        const Self = @This();

        pub const width: u16 = W;
        pub const height: u16 = H;
        pub const format: ColorFormat = fmt;

        buf: [BufLen]Color,
        dirty: DirtyTracker(DIRTY_MAX),

        /// Initialize framebuffer filled with a single color.
        pub fn init(fill: Color) Self {
            return .{
                .buf = [_]Color{fill} ** BufLen,
                .dirty = DirtyTracker(DIRTY_MAX).init(),
            };
        }

        // ================================================================
        // Drawing Primitives
        // ================================================================

        /// Clear entire framebuffer to a color.
        pub fn clear(self: *Self, color: Color) void {
            @memset(&self.buf, color);
            self.dirty.markAll(W, H);
        }

        /// Set a single pixel. No-op if out of bounds.
        pub fn setPixel(self: *Self, x: u16, y: u16, color: Color) void {
            if (x >= W or y >= H) return;
            self.buf[@as(usize, y) * W + @as(usize, x)] = color;
            self.dirty.mark(.{ .x = x, .y = y, .w = 1, .h = 1 });
        }

        /// Get a single pixel. Returns 0 if out of bounds.
        pub fn getPixel(self: *const Self, x: u16, y: u16) Color {
            if (x >= W or y >= H) return 0;
            return self.buf[@as(usize, y) * W + @as(usize, x)];
        }

        /// Fill a rectangle with a solid color. Clips to framebuffer bounds.
        pub fn fillRect(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color) void {
            fillRectPixels(self, x, y, w, h, color);
            const clip = clipRect(x, y, w, h);
            if (clip.w > 0 and clip.h > 0) self.dirty.mark(clip);
        }

        /// Fill pixels without marking dirty (for composite operations that mark once at end).
        fn fillRectPixels(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color) void {
            const clip = clipRect(x, y, w, h);
            if (clip.w == 0 or clip.h == 0) return;
            var row: u16 = clip.y;
            while (row < clip.y + clip.h) : (row += 1) {
                const start = @as(usize, row) * W + @as(usize, clip.x);
                @memset(self.buf[start..][0..clip.w], color);
            }
        }

        /// Draw a rectangle outline. Clips to framebuffer bounds.
        pub fn drawRect(self: *Self, x: u16, y: u16, w: u16, h: u16, color: Color, thickness: u8) void {
            if (w == 0 or h == 0) return;
            const t: u16 = @min(@as(u16, thickness), @min(w / 2, h / 2));
            if (t == 0) return;

            // Top edge
            self.fillRect(x, y, w, t, color);
            // Bottom edge
            if (h > t) self.fillRect(x, y + h - t, w, t, color);
            // Left edge (between top and bottom)
            if (h > 2 * t) self.fillRect(x, y + t, t, h - 2 * t, color);
            // Right edge
            if (h > 2 * t and w > t) self.fillRect(x + w - t, y + t, t, h - 2 * t, color);
        }

        /// Fill a rounded rectangle. Clips to bounds.
        pub fn fillRoundRect(self: *Self, x: u16, y: u16, w: u16, h: u16, radius: u8, color: Color) void {
            if (w == 0 or h == 0) return;
            const r: u16 = @min(radius, @min(w / 2, h / 2));
            if (r == 0) {
                self.fillRect(x, y, w, h, color);
                return;
            }
            // Draw pixels without marking dirty (single mark at end)
            fillRectPixels(self, x, y + r, w, h - 2 * r, color);
            fillRectPixels(self, x + r, y, w - 2 * r, r, color);
            fillRectPixels(self, x + r, y + h - r, w - 2 * r, r, color);
            self.fillCorners(x, y, w, h, r, color);
            // One dirty mark for the entire rounded rect
            self.dirty.mark(clipRect(x, y, w, h));
        }

        fn fillCorners(self: *Self, x: u16, y: u16, w: u16, h: u16, r: u16, color: Color) void {
            var cx: i32 = 0;
            var cy: i32 = @intCast(r);
            var d: i32 = 1 - @as(i32, @intCast(r));

            while (cx <= cy) {
                // Top-left corner
                self.hlineClipped(x + r - @as(u16, @intCast(cy)), y + r - @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + r - @as(u16, @intCast(cx)), y + r - @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);
                // Top-right corner
                self.hlineClipped(x + w - r - 1, y + r - @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + w - r - 1, y + r - @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);
                // Bottom-left corner
                self.hlineClipped(x + r - @as(u16, @intCast(cy)), y + h - r - 1 + @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + r - @as(u16, @intCast(cx)), y + h - r - 1 + @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);
                // Bottom-right corner
                self.hlineClipped(x + w - r - 1, y + h - r - 1 + @as(u16, @intCast(cx)), @as(u16, @intCast(cy)) + 1, color);
                self.hlineClipped(x + w - r - 1, y + h - r - 1 + @as(u16, @intCast(cy)), @as(u16, @intCast(cx)) + 1, color);

                if (d < 0) {
                    d += 2 * cx + 3;
                } else {
                    d += 2 * (cx - cy) + 5;
                    cy -= 1;
                }
                cx += 1;
            }
        }

        fn hlineClipped(self: *Self, x: u16, y: u16, len: u16, color: Color) void {
            if (y >= H or x >= W) return;
            const actual_len = @min(len, W - x);
            const start = @as(usize, y) * W + @as(usize, x);
            @memset(self.buf[start..][0..actual_len], color);
        }

        /// Draw a horizontal line. Fast path (single memset).
        pub fn hline(self: *Self, x: u16, y: u16, len: u16, color: Color) void {
            self.fillRect(x, y, len, 1, color);
        }

        /// Draw a vertical line.
        pub fn vline(self: *Self, x: u16, y: u16, len: u16, color: Color) void {
            self.fillRect(x, y, 1, len, color);
        }

        /// Blit an image onto the framebuffer. Clips to bounds.
        pub fn blit(self: *Self, x: u16, y: u16, img: Image) void {
            self.blitInternal(x, y, img, null);
        }

        /// Blit with transparency — skip pixels matching the transparent color.
        pub fn blitTransparent(self: *Self, x: u16, y: u16, img: Image, transparent: Color) void {
            self.blitInternal(x, y, img, transparent);
        }

        fn blitInternal(self: *Self, x: u16, y: u16, img: Image, transparent: ?Color) void {
            if (img.width == 0 or img.height == 0) return;

            // Dispatch to alpha blit for 3bpp (RGBA5658) images
            if (img.bytes_per_pixel == 3 and fmt == .rgb565) {
                self.blitAlpha(x, y, img);
                return;
            }

            const clip = clipRect(x, y, img.width, img.height);
            if (clip.w == 0 or clip.h == 0) return;

            const src_offset_x = clip.x - x;
            const src_offset_y = clip.y - y;

            var row: u16 = 0;
            while (row < clip.h) : (row += 1) {
                var col: u16 = 0;
                while (col < clip.w) : (col += 1) {
                    const px = img.getPixelTyped(Color, src_offset_x + col, src_offset_y + row);
                    if (transparent) |t| {
                        if (px == t) continue;
                    }
                    const dst_idx = @as(usize, clip.y + row) * W + @as(usize, clip.x + col);
                    self.buf[dst_idx] = px;
                }
            }
            self.dirty.mark(clip);
        }

        /// Blit a 3bpp RGBA5658 image with per-pixel alpha blending.
        fn blitAlpha(self: *Self, x: u16, y: u16, img: Image) void {
            const clip = clipRect(x, y, img.width, img.height);
            if (clip.w == 0 or clip.h == 0) return;

            const src_ox = clip.x - x;
            const src_oy = clip.y - y;

            var row: u16 = 0;
            while (row < clip.h) : (row += 1) {
                var col: u16 = 0;
                while (col < clip.w) : (col += 1) {
                    const sx = src_ox + col;
                    const sy = src_oy + row;
                    const offset = (@as(usize, sy) * @as(usize, img.width) + @as(usize, sx)) * 3;
                    if (offset + 3 > img.data.len) continue;

                    const alpha = img.data[offset + 2];
                    if (alpha == 0) continue; // fully transparent

                    const rgb565: u16 = @as(u16, img.data[offset]) | (@as(u16, img.data[offset + 1]) << 8);
                    const dst_idx = @as(usize, clip.y + row) * W + @as(usize, clip.x + col);

                    if (alpha >= 250) {
                        self.buf[dst_idx] = rgb565;
                    } else {
                        self.buf[dst_idx] = blendRgb565(self.buf[dst_idx], rgb565, alpha);
                    }
                }
            }
            self.dirty.mark(clip);
        }

        /// Draw a UTF-8 text string with a bitmap font.
        pub fn drawText(self: *Self, x: u16, y: u16, text: []const u8, fnt: *const BitmapFont, color: Color) void {
            if (text.len == 0 or fnt.glyph_w == 0 or fnt.glyph_h == 0) return;

            var cx: u16 = x;
            var i: usize = 0;
            while (i < text.len) {
                const decoded = font_mod.decodeUtf8(text[i..]);
                i += decoded.len;

                if (decoded.codepoint) |cp| {
                    if (cx + fnt.glyph_w > W) break;
                    if (fnt.getGlyph(cp) != null) {
                        self.drawGlyph(cx, y, fnt, cp, color);
                        cx += fnt.glyph_w;
                    }
                }
            }

            // Mark the entire text region dirty (one rect)
            if (cx > x) {
                const text_w = cx - x;
                const text_h = @min(fnt.glyph_h, if (y < H) H - y else 0);
                if (text_w > 0 and text_h > 0) {
                    self.dirty.mark(.{ .x = x, .y = y, .w = text_w, .h = text_h });
                }
            }
        }

        fn drawGlyph(self: *Self, x: u16, y: u16, fnt: *const BitmapFont, codepoint: u21, color: Color) void {
            const glyph_data = fnt.getGlyph(codepoint) orelse return;
            const bytes_per_row = (fnt.glyph_w + 7) / 8;

            var row: u16 = 0;
            while (row < fnt.glyph_h) : (row += 1) {
                if (y + row >= H) break;
                var col: u16 = 0;
                while (col < fnt.glyph_w) : (col += 1) {
                    if (x + col >= W) break;
                    const byte_idx = @as(usize, row) * bytes_per_row + @as(usize, col) / 8;
                    if (byte_idx >= glyph_data.len) continue;
                    const bit = @as(u8, 0x80) >> @intCast(col % 8);
                    if (glyph_data[byte_idx] & bit != 0) {
                        const dst_idx = @as(usize, y + row) * W + @as(usize, x + col);
                        self.buf[dst_idx] = color;
                    }
                }
            }
        }

        /// Draw a UTF-8 text string with a TrueType font (anti-aliased alpha blending).
        pub fn drawTextTtf(self: *Self, x: u16, y: u16, text: []const u8, fnt: *TtfFont, color: Color) void {
            if (text.len == 0) return;

            var cx: u16 = x;
            const baseline: u16 = y + @as(u16, @intCast(@max(0, fnt.ascent)));
            var min_x: u16 = x;
            var max_x: u16 = x;
            var min_y: u16 = y;
            var max_y: u16 = y;
            var i: usize = 0;
            while (i < text.len) {
                const decoded = font_mod.decodeUtf8(text[i..]);
                i += decoded.len;

                if (decoded.codepoint) |cp| {
                    if (fnt.getGlyph(cp)) |g| {
                        const dx: i32 = @as(i32, cx) + g.x_off;
                        const dy: i32 = @as(i32, baseline) + g.y_off;

                        var gy: u16 = 0;
                        while (gy < g.h) : (gy += 1) {
                            const py = dy + gy;
                            if (py < 0 or py >= H) continue;
                            const upy: u16 = @intCast(py);
                            var gx: u16 = 0;
                            while (gx < g.w) : (gx += 1) {
                                const px = dx + gx;
                                if (px < 0 or px >= W) continue;
                                const alpha = g.bitmap[@as(usize, gy) * g.w + @as(usize, gx)];
                                if (alpha > 0) {
                                    const upx: u16 = @intCast(px);
                                    const dst_idx = @as(usize, upy) * W + @as(usize, upx);
                                    if (alpha >= 250) {
                                        self.buf[dst_idx] = color;
                                    } else {
                                        self.buf[dst_idx] = blendRgb565(self.buf[dst_idx], color, alpha);
                                    }
                                    if (upx < min_x) min_x = upx;
                                    if (upx + 1 > max_x) max_x = upx + 1;
                                    if (upy < min_y) min_y = upy;
                                    if (upy + 1 > max_y) max_y = upy + 1;
                                }
                            }
                        }
                        cx += g.advance;
                        if (cx >= W) break;
                    }
                }
            }

            if (max_x > min_x and max_y > min_y) {
                self.dirty.mark(.{ .x = min_x, .y = min_y, .w = max_x - min_x, .h = max_y - min_y });
            }
        }

        /// Alpha-blend two RGB565 colors
        fn blendRgb565(bg: Color, fg: Color, alpha: u8) Color {
            if (Color != u16) return fg; // only RGB565 supported
            const a: u32 = alpha;
            const inv_a: u32 = 255 - a;
            // Extract components
            const bg_r = (bg >> 11) & 0x1F;
            const bg_g = (bg >> 5) & 0x3F;
            const bg_b = bg & 0x1F;
            const fg_r = (fg >> 11) & 0x1F;
            const fg_g = (fg >> 5) & 0x3F;
            const fg_b = fg & 0x1F;
            // Blend
            const r: u16 = @intCast((fg_r * a + bg_r * inv_a) / 255);
            const g: u16 = @intCast((fg_g * a + bg_g * inv_a) / 255);
            const b: u16 = @intCast((fg_b * a + bg_b * inv_a) / 255);
            return (r << 11) | (g << 5) | b;
        }

        // ================================================================
        // Display Flush Support
        // ================================================================

        /// Get accumulated dirty regions for partial display flush.
        pub fn getDirtyRects(self: *const Self) []const Rect {
            return self.dirty.get();
        }

        /// Clear dirty tracking after display flush.
        pub fn clearDirty(self: *Self) void {
            self.dirty.clear();
        }

        /// Extract a rectangular sub-region as contiguous pixels (no stride).
        ///
        /// Copies pixels row-by-row from the framebuffer into `out`,
        /// removing the stride gap. The result can be passed directly
        /// to SpiLcd.flush().
        ///
        /// Returns the filled portion of `out`.
        pub fn getRegion(self: *const Self, rect: Rect, out: []Color) []const Color {
            const clip = clipRect(rect.x, rect.y, rect.w, rect.h);
            if (clip.w == 0 or clip.h == 0) return out[0..0];

            const pixels_needed = @as(usize, clip.w) * @as(usize, clip.h);
            if (out.len < pixels_needed) return out[0..0];

            var i: usize = 0;
            var row: u16 = clip.y;
            while (row < clip.y + clip.h) : (row += 1) {
                const src_start = @as(usize, row) * W + @as(usize, clip.x);
                @memcpy(out[i..][0..clip.w], self.buf[src_start..][0..clip.w]);
                i += clip.w;
            }
            return out[0..pixels_needed];
        }

        /// Get raw buffer pointer (for full-screen flush).
        pub fn getBuffer(self: *const Self) []const Color {
            return &self.buf;
        }

        // ================================================================
        // Internal helpers
        // ================================================================

        /// Clip a rectangle to framebuffer bounds.
        fn clipRect(x: u16, y: u16, w: u16, h: u16) Rect {
            if (x >= W or y >= H) return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
            return .{
                .x = x,
                .y = y,
                .w = @min(w, W - x),
                .h = @min(h, H - y),
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

const TestFB = Framebuffer(16, 16, .rgb565);

test "init fills buffer" {
    const fb = TestFB.init(0x1234);
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(0, 0));
    try testing.expectEqual(@as(u16, 0x1234), fb.getPixel(15, 15));
}

test "setPixel and getPixel" {
    var fb = TestFB.init(0);
    fb.setPixel(5, 7, 0xF800);
    try testing.expectEqual(@as(u16, 0xF800), fb.getPixel(5, 7));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(5, 6));
}

test "setPixel out of bounds is no-op" {
    var fb = TestFB.init(0);
    fb.setPixel(16, 0, 0xFFFF); // x out of bounds
    fb.setPixel(0, 16, 0xFFFF); // y out of bounds
    try testing.expectEqual(@as(u16, 0), fb.getPixel(15, 15));
}

test "getPixel out of bounds returns 0" {
    const fb = TestFB.init(0x1234);
    try testing.expectEqual(@as(u16, 0), fb.getPixel(16, 0));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(0, 16));
}

test "fillRect writes pixels" {
    var fb = TestFB.init(0);
    fb.fillRect(2, 3, 4, 5, 0x07E0);

    // Inside rect
    try testing.expectEqual(@as(u16, 0x07E0), fb.getPixel(2, 3));
    try testing.expectEqual(@as(u16, 0x07E0), fb.getPixel(5, 7));

    // Outside rect
    try testing.expectEqual(@as(u16, 0), fb.getPixel(1, 3));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(6, 3));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(2, 2));
    try testing.expectEqual(@as(u16, 0), fb.getPixel(2, 8));
}

test "fillRect clips to bounds" {
    var fb = TestFB.init(0);
    fb.fillRect(14, 14, 10, 10, 0xFFFF); // extends past 16x16

    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(14, 14));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(15, 15));
    // Should not crash — clipped to 2x2
}

test "fillRect marks dirty" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    fb.fillRect(5, 5, 3, 3, 0x1111);

    const rects = fb.getDirtyRects();
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 5), rects[0].x);
    try testing.expectEqual(@as(u16, 5), rects[0].y);
    try testing.expectEqual(@as(u16, 3), rects[0].w);
    try testing.expectEqual(@as(u16, 3), rects[0].h);
}

test "drawRect draws outline" {
    var fb = TestFB.init(0);
    fb.drawRect(2, 2, 8, 8, 0xFFFF, 1);

    // Top edge
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(2, 2));
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(9, 2));
    // Bottom edge
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(2, 9));
    // Left edge
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(2, 5));
    // Right edge
    try testing.expectEqual(@as(u16, 0xFFFF), fb.getPixel(9, 5));
    // Interior is empty
    try testing.expectEqual(@as(u16, 0), fb.getPixel(5, 5));
}

test "hline and vline" {
    var fb = TestFB.init(0);
    fb.hline(0, 8, 16, 0xAAAA);
    fb.vline(8, 0, 16, 0xBBBB);

    try testing.expectEqual(@as(u16, 0xAAAA), fb.getPixel(0, 8));
    try testing.expectEqual(@as(u16, 0xAAAA), fb.getPixel(15, 8));
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(8, 0));
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(8, 15));
    // Intersection — vline overwrites hline
    try testing.expectEqual(@as(u16, 0xBBBB), fb.getPixel(8, 8));
}

test "clear marks all dirty" {
    var fb = TestFB.init(0);
    fb.clearDirty();
    fb.clear(0x1234);

    const rects = fb.getDirtyRects();
    try testing.expectEqual(@as(usize, 1), rects.len);
    try testing.expectEqual(@as(u16, 0), rects[0].x);
    try testing.expectEqual(@as(u16, 0), rects[0].y);
    try testing.expectEqual(@as(u16, 16), rects[0].w);
    try testing.expectEqual(@as(u16, 16), rects[0].h);
}

test "getRegion extracts contiguous pixels" {
    var fb = TestFB.init(0);
    // Fill a 3x3 area at (2,2) with distinct values
    fb.setPixel(2, 2, 0x0001);
    fb.setPixel(3, 2, 0x0002);
    fb.setPixel(4, 2, 0x0003);
    fb.setPixel(2, 3, 0x0004);
    fb.setPixel(3, 3, 0x0005);
    fb.setPixel(4, 3, 0x0006);

    var out: [6]u16 = undefined;
    const region = fb.getRegion(.{ .x = 2, .y = 2, .w = 3, .h = 2 }, &out);

    try testing.expectEqual(@as(usize, 6), region.len);
    // Row 0: (2,2), (3,2), (4,2)
    try testing.expectEqual(@as(u16, 0x0001), region[0]);
    try testing.expectEqual(@as(u16, 0x0002), region[1]);
    try testing.expectEqual(@as(u16, 0x0003), region[2]);
    // Row 1: (2,3), (3,3), (4,3)
    try testing.expectEqual(@as(u16, 0x0004), region[3]);
    try testing.expectEqual(@as(u16, 0x0005), region[4]);
    try testing.expectEqual(@as(u16, 0x0006), region[5]);
}

test "getRegion clips to bounds" {
    const fb = TestFB.init(0x1111);
    var out: [256]u16 = undefined;
    const region = fb.getRegion(.{ .x = 14, .y = 14, .w = 10, .h = 10 }, &out);

    // Clipped to 2x2
    try testing.expectEqual(@as(usize, 4), region.len);
}

test "getRegion returns empty for out-of-bounds" {
    const fb = TestFB.init(0);
    var out: [10]u16 = undefined;
    const region = fb.getRegion(.{ .x = 20, .y = 20, .w = 5, .h = 5 }, &out);
    try testing.expectEqual(@as(usize, 0), region.len);
}
