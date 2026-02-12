//! Display Types
//!
//! Common types used across display drivers and UI frameworks.

/// Color format of the display framebuffer
pub const ColorFormat = enum {
    rgb565, // 16-bit, 2 bytes per pixel — most common for embedded
    rgb888, // 24-bit, 3 bytes per pixel
    xrgb8888, // 32-bit, 4 bytes per pixel (X channel ignored)
    argb8888, // 32-bit, 4 bytes per pixel with alpha
};

/// How the UI framework manages its draw buffer.
///
/// Determines buffer allocation strategy and LVGL render mode.
/// Configured in the board's display_spec.
pub const RenderMode = enum {
    /// SPI/I2C LCD — render in chunks of `buf_lines` rows.
    /// Buffer size: width * bpp * buf_lines.
    /// Flush sends pixels over the bus.
    partial,

    /// RGB parallel LCD — LVGL writes directly into driver framebuffer.
    /// Driver must implement `getFramebuffer() [*]u8`.
    /// Flush signals "area updated" (may trigger DMA or no-op).
    direct,

    /// Simulator / ample-RAM — render entire frame then flush.
    /// Buffer size: width * bpp * height (full frame).
    full,
};

/// Rectangular area on the display
pub const Area = struct {
    x1: u16,
    y1: u16,
    x2: u16, // inclusive
    y2: u16, // inclusive

    pub fn width(self: Area) u16 {
        return self.x2 - self.x1 + 1;
    }

    pub fn height(self: Area) u16 {
        return self.y2 - self.y1 + 1;
    }

    pub fn pixelCount(self: Area) u32 {
        return @as(u32, self.width()) * @as(u32, self.height());
    }
};

/// Bytes per pixel for a given color format
pub fn bytesPerPixel(format: ColorFormat) u8 {
    return switch (format) {
        .rgb565 => 2,
        .rgb888 => 3,
        .xrgb8888, .argb8888 => 4,
    };
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "Area calculations" {
    const area = Area{ .x1 = 10, .y1 = 20, .x2 = 109, .y2 = 59 };
    try std.testing.expectEqual(@as(u16, 100), area.width());
    try std.testing.expectEqual(@as(u16, 40), area.height());
    try std.testing.expectEqual(@as(u32, 4000), area.pixelCount());
}

test "bytesPerPixel" {
    try std.testing.expectEqual(@as(u8, 2), bytesPerPixel(.rgb565));
    try std.testing.expectEqual(@as(u8, 3), bytesPerPixel(.rgb888));
    try std.testing.expectEqual(@as(u8, 4), bytesPerPixel(.xrgb8888));
    try std.testing.expectEqual(@as(u8, 4), bytesPerPixel(.argb8888));
}
