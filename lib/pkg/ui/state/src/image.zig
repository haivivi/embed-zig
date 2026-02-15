//! Image — Raw Pixel Data for Blitting
//!
//! Describes a rectangular block of pixel data that can be blitted
//! onto a Framebuffer. The pixel format should match the target
//! framebuffer's ColorFormat.
//!
//! Image does not own its data — it references external storage
//! (e.g., @embedFile, flash, or heap-allocated bitmap).

/// Raw image descriptor.
pub const Image = struct {
    /// Image width in pixels.
    width: u16,
    /// Image height in pixels.
    height: u16,
    /// Raw pixel data. Layout: row-major, tightly packed.
    /// For RGB565: 2 bytes per pixel (little-endian u16).
    /// For ARGB8888: 4 bytes per pixel.
    data: []const u8,
    /// Bytes per pixel (must match target framebuffer format).
    bytes_per_pixel: u8,

    /// Get a pixel value at (x, y) as a raw u32.
    /// Returns 0 if out of bounds or data is too short.
    pub fn getPixel(self: *const Image, x: u16, y: u16) u32 {
        if (x >= self.width or y >= self.height) return 0;
        const bpp = @as(usize, self.bytes_per_pixel);
        const offset = (@as(usize, y) * @as(usize, self.width) + @as(usize, x)) * bpp;
        if (offset + bpp > self.data.len) return 0;

        return switch (self.bytes_per_pixel) {
            2 => @as(u32, self.data[offset]) | (@as(u32, self.data[offset + 1]) << 8),
            3 => @as(u32, self.data[offset]) |
                (@as(u32, self.data[offset + 1]) << 8) |
                (@as(u32, self.data[offset + 2]) << 16),
            4 => @as(u32, self.data[offset]) |
                (@as(u32, self.data[offset + 1]) << 8) |
                (@as(u32, self.data[offset + 2]) << 16) |
                (@as(u32, self.data[offset + 3]) << 24),
            else => 0,
        };
    }

    /// Get a pixel value cast to the framebuffer's Color type.
    /// Used internally by Framebuffer.blit().
    pub fn getPixelTyped(self: *const Image, comptime Color: type, x: u16, y: u16) Color {
        const raw = self.getPixel(x, y);
        return @truncate(raw);
    }

    /// Total size in bytes.
    pub fn dataSize(self: *const Image) usize {
        return @as(usize, self.width) * @as(usize, self.height) * @as(usize, self.bytes_per_pixel);
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = @import("std").testing;

test "Image.getPixel RGB565" {
    // 2x2 RGB565 image: pixel values 0x1234, 0x5678, 0x9ABC, 0xDEF0
    const data = [_]u8{
        0x34, 0x12, // (0,0) = 0x1234
        0x78, 0x56, // (1,0) = 0x5678
        0xBC, 0x9A, // (0,1) = 0x9ABC
        0xF0, 0xDE, // (1,1) = 0xDEF0
    };

    const img = Image{
        .width = 2,
        .height = 2,
        .data = &data,
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(u32, 0x1234), img.getPixel(0, 0));
    try testing.expectEqual(@as(u32, 0x5678), img.getPixel(1, 0));
    try testing.expectEqual(@as(u32, 0x9ABC), img.getPixel(0, 1));
    try testing.expectEqual(@as(u32, 0xDEF0), img.getPixel(1, 1));
}

test "Image.getPixel out of bounds" {
    const data = [_]u8{ 0xFF, 0xFF };
    const img = Image{
        .width = 1,
        .height = 1,
        .data = &data,
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(u32, 0), img.getPixel(1, 0));
    try testing.expectEqual(@as(u32, 0), img.getPixel(0, 1));
}

test "Image.getPixelTyped u16" {
    const data = [_]u8{ 0x00, 0xF8 }; // 0xF800 (red in RGB565)
    const img = Image{
        .width = 1,
        .height = 1,
        .data = &data,
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(u16, 0xF800), img.getPixelTyped(u16, 0, 0));
}

test "Image.dataSize" {
    const img = Image{
        .width = 10,
        .height = 20,
        .data = &[_]u8{},
        .bytes_per_pixel = 2,
    };

    try testing.expectEqual(@as(usize, 400), img.dataSize());
}
