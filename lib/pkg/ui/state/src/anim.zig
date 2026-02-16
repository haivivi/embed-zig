//! Animation Player — decodes and plays .anim frame-diff files
//!
//! Format (produced by tools/mp4todiff):
//!   Header (14 bytes):
//!     [0:2]   u16 LE  display_width (original size, e.g. 240)
//!     [2:4]   u16 LE  display_height
//!     [4:6]   u16 LE  frame_width (scaled, e.g. 120)
//!     [6:8]   u16 LE  frame_height
//!     [8:10]  u16 LE  frame_count
//!     [10]    u8      fps
//!     [11]    u8      scale factor (e.g. 2 = each pixel drawn as 2x2)
//!     [12:14] u16 LE  palette_size
//!   Palette: palette_size × 2 bytes (RGB565 LE)
//!   Per frame:
//!     [+0]    u16 LE  rect_count
//!     Per rect:
//!       [+0]  u16 LE  x, y, w, h (in frame coords)
//!       [+8]  RLE data: [count-1 (u8)] [palette_index (u8)] pairs
//!
//! Usage:
//!   var player = AnimPlayer.init(anim_data);
//!   while (player.nextFrame()) |frame| {
//!       for (frame.rects) |rect| {
//!           // blit rect.pixels to framebuffer at rect.x * scale, rect.y * scale
//!       }
//!   }

const framebuffer_mod = @import("framebuffer.zig");

/// Animation header parsed from .anim data
pub const AnimHeader = struct {
    display_w: u16,
    display_h: u16,
    frame_w: u16,
    frame_h: u16,
    frame_count: u16,
    fps: u8,
    scale: u8,
    palette_size: u16,
};

/// A single dirty rect within a frame
pub const AnimRect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    /// Decoded RGB565 pixels (w * h), stored in player's decode buffer
    pixels: []const u16,
};

/// Maximum rects per frame
const MAX_RECTS = 192;
/// Maximum pixels per frame decode buffer (must accommodate full frame + overlap from multiple rects)
const MAX_FRAME_PIXELS = 160 * 160; // generous buffer for multi-rect frames

/// Decoded frame — returned by nextFrame()
pub const AnimFrame = struct {
    rects: []const AnimRect,
    frame_index: u16,
};

/// Animation player — streams through .anim data one frame at a time.
/// Zero-alloc: uses internal fixed buffers for decode.
pub const AnimPlayer = struct {
    const Self = @This();

    data: []const u8,
    header: AnimHeader,
    palette: []const u8, // raw palette bytes (palette_size * 2)
    pos: usize, // current read position in data
    frame_index: u16,

    // Decode buffers
    rect_buf: [MAX_RECTS]AnimRect = undefined,
    pixel_buf: [MAX_FRAME_PIXELS]u16 = undefined,

    /// Initialize from .anim file data (zero-copy from VFS)
    pub fn init(anim_data: []const u8) ?Self {
        if (anim_data.len < 14) return null;

        const h = AnimHeader{
            .display_w = readU16(anim_data, 0),
            .display_h = readU16(anim_data, 2),
            .frame_w = readU16(anim_data, 4),
            .frame_h = readU16(anim_data, 6),
            .frame_count = readU16(anim_data, 8),
            .fps = anim_data[10],
            .scale = anim_data[11],
            .palette_size = readU16(anim_data, 12),
        };

        const palette_bytes = @as(usize, h.palette_size) * 2;
        if (anim_data.len < 14 + palette_bytes) return null;

        return Self{
            .data = anim_data,
            .header = h,
            .palette = anim_data[14..][0..palette_bytes],
            .pos = 14 + palette_bytes,
            .frame_index = 0,
        };
    }

    /// Decode and return the next frame. Returns null when animation is done.
    pub fn nextFrame(self: *Self) ?AnimFrame {
        if (self.frame_index >= self.header.frame_count) return null;
        if (self.pos + 2 > self.data.len) return null;

        const rect_count = readU16(self.data, self.pos);
        self.pos += 2;

        if (rect_count > MAX_RECTS) return null;

        var pixel_offset: usize = 0;

        for (0..rect_count) |i| {
            if (self.pos + 8 > self.data.len) return null;

            const rx = readU16(self.data, self.pos);
            const ry = readU16(self.data, self.pos + 2);
            const rw = readU16(self.data, self.pos + 4);
            const rh = readU16(self.data, self.pos + 6);
            self.pos += 8;

            const pixel_count = @as(usize, rw) * @as(usize, rh);
            if (pixel_offset + pixel_count > MAX_FRAME_PIXELS) return null;

            // Decode RLE into pixel_buf
            var decoded: usize = 0;
            while (decoded < pixel_count) {
                if (self.pos + 2 > self.data.len) return null;
                const run_len = @as(usize, self.data[self.pos]) + 1; // stored as count-1
                const pal_idx = self.data[self.pos + 1];
                self.pos += 2;

                // Look up palette color
                const color = paletteColor(self.palette, pal_idx);

                const actual = @min(run_len, pixel_count - decoded);
                @memset(self.pixel_buf[pixel_offset + decoded ..][0..actual], color);
                decoded += actual;
            }

            self.rect_buf[i] = AnimRect{
                .x = rx,
                .y = ry,
                .w = rw,
                .h = rh,
                .pixels = self.pixel_buf[pixel_offset..][0..pixel_count],
            };
            pixel_offset += pixel_count;
        }

        const frame = AnimFrame{
            .rects = self.rect_buf[0..rect_count],
            .frame_index = self.frame_index,
        };
        self.frame_index += 1;
        return frame;
    }

    /// Reset to first frame (replay)
    pub fn reset(self: *Self) void {
        self.pos = 14 + @as(usize, self.header.palette_size) * 2;
        self.frame_index = 0;
    }

    /// Milliseconds per frame
    pub fn frameDurationMs(self: *const Self) u32 {
        if (self.header.fps == 0) return 33; // default ~30fps
        return 1000 / @as(u32, self.header.fps);
    }

    /// Is animation complete?
    pub fn isDone(self: *const Self) bool {
        return self.frame_index >= self.header.frame_count;
    }
};

/// Blit an animation frame to a Framebuffer, applying scale factor.
/// Each pixel in the frame is drawn as scale×scale pixels on the framebuffer.
pub fn blitAnimFrame(
    comptime W: u16,
    comptime H: u16,
    comptime fmt: framebuffer_mod.ColorFormat,
    fb: *framebuffer_mod.Framebuffer(W, H, fmt),
    frame: AnimFrame,
    scale: u8,
) void {
    for (frame.rects) |rect| {
        if (scale == 1) {
            // 1:1 — direct blit
            var row: u16 = 0;
            while (row < rect.h) : (row += 1) {
                var col: u16 = 0;
                while (col < rect.w) : (col += 1) {
                    const px = rect.pixels[@as(usize, row) * rect.w + @as(usize, col)];
                    fb.setPixel(rect.x + col, rect.y + row, px);
                }
            }
        } else {
            // Scaled — each source pixel → scale×scale destination pixels
            const s: u16 = scale;
            var row: u16 = 0;
            while (row < rect.h) : (row += 1) {
                var col: u16 = 0;
                while (col < rect.w) : (col += 1) {
                    const px = rect.pixels[@as(usize, row) * rect.w + @as(usize, col)];
                    const dx = rect.x * s + col * s;
                    const dy = rect.y * s + row * s;
                    fb.fillRect(dx, dy, s, s, px);
                }
            }
        }
    }
}

// ============================================================================
// Helpers
// ============================================================================

fn readU16(data: []const u8, offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn paletteColor(palette: []const u8, idx: u8) u16 {
    const offset = @as(usize, idx) * 2;
    if (offset + 2 > palette.len) return 0;
    return @as(u16, palette[offset]) | (@as(u16, palette[offset + 1]) << 8);
}

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "AnimPlayer: parse header" {
    // Minimal valid .anim: 1x1 frame, 1 frame, 2-color palette, 1 rect (full), 1 pixel
    var data: [14 + 4 + 2 + 8 + 2]u8 = undefined;
    // Header
    data[0] = 2; data[1] = 0; // display_w = 2
    data[2] = 2; data[3] = 0; // display_h = 2
    data[4] = 1; data[5] = 0; // frame_w = 1
    data[6] = 1; data[7] = 0; // frame_h = 1
    data[8] = 1; data[9] = 0; // frame_count = 1
    data[10] = 15; // fps
    data[11] = 2; // scale
    data[12] = 2; data[13] = 0; // palette_size = 2
    // Palette: color 0 = 0x0000 (black), color 1 = 0xFFFF (white)
    data[14] = 0; data[15] = 0;
    data[16] = 0xFF; data[17] = 0xFF;
    // Frame 0: 1 rect
    data[18] = 1; data[19] = 0; // rect_count = 1
    // Rect: x=0, y=0, w=1, h=1
    data[20] = 0; data[21] = 0; data[22] = 0; data[23] = 0;
    data[24] = 1; data[25] = 0; data[26] = 1; data[27] = 0;
    // RLE: 1 pixel, palette index 1 (white)
    data[28] = 0; // count-1 = 0 → 1 pixel
    data[29] = 1; // palette index 1

    var player = AnimPlayer.init(&data) orelse return error.TestUnexpectedResult;

    try testing.expectEqual(@as(u16, 2), player.header.display_w);
    try testing.expectEqual(@as(u16, 1), player.header.frame_w);
    try testing.expectEqual(@as(u16, 1), player.header.frame_count);
    try testing.expectEqual(@as(u8, 15), player.header.fps);
    try testing.expectEqual(@as(u8, 2), player.header.scale);

    // Decode frame
    const frame = player.nextFrame() orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), frame.rects.len);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[0]); // white

    // No more frames
    try testing.expectEqual(@as(?AnimFrame, null), player.nextFrame());
    try testing.expect(player.isDone());
}

test "AnimPlayer: RLE decode multiple runs" {
    // 1 frame, 4x1 pixels: [black, black, white, white]
    var data: [14 + 4 + 2 + 8 + 4]u8 = undefined;
    data[0] = 4; data[1] = 0; data[2] = 1; data[3] = 0; // display 4x1
    data[4] = 4; data[5] = 0; data[6] = 1; data[7] = 0; // frame 4x1
    data[8] = 1; data[9] = 0; // 1 frame
    data[10] = 30; data[11] = 1; // 30fps, scale 1
    data[12] = 2; data[13] = 0; // 2 colors
    data[14] = 0; data[15] = 0; // black
    data[16] = 0xFF; data[17] = 0xFF; // white
    data[18] = 1; data[19] = 0; // 1 rect
    data[20] = 0; data[21] = 0; data[22] = 0; data[23] = 0; // x=0,y=0
    data[24] = 4; data[25] = 0; data[26] = 1; data[27] = 0; // w=4,h=1
    // RLE: 2 black, 2 white
    data[28] = 1; data[29] = 0; // count=2, idx=0 (black)
    data[30] = 1; data[31] = 1; // count=2, idx=1 (white)

    var player = AnimPlayer.init(&data).?;
    const frame = player.nextFrame().?;

    try testing.expectEqual(@as(u16, 0x0000), frame.rects[0].pixels[0]);
    try testing.expectEqual(@as(u16, 0x0000), frame.rects[0].pixels[1]);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[2]);
    try testing.expectEqual(@as(u16, 0xFFFF), frame.rects[0].pixels[3]);
}
