//! Memory-backed display driver for testing
//!
//! Implements the display surface driver interface with an in-memory
//! framebuffer. Used for headless testing of LVGL integration —
//! no hardware or graphics system needed.
//!
//! After running LVGL tick/handler cycles, you can inspect:
//! - `flush_count`: number of times flush was called
//! - `framebuffer`: raw pixel data to verify rendering
//! - `getPixel()`: read individual pixel values

const types = @import("types.zig");
const Area = types.Area;
const ColorFormat = types.ColorFormat;
const RenderMode = types.RenderMode;
const bytesPerPixel = types.bytesPerPixel;

/// Memory-backed display driver.
///
/// Generic over resolution and color format to match any display spec.
pub fn MemDisplay(
    comptime w: u16,
    comptime h: u16,
    comptime color_fmt: ColorFormat,
) type {
    const bpp = bytesPerPixel(color_fmt);
    const fb_size = @as(u32, w) * @as(u32, h) * @as(u32, bpp);

    return struct {
        const Self = @This();

        // -- Display driver comptime interface --
        pub const width: u16 = w;
        pub const height: u16 = h;
        pub const color_format: ColorFormat = color_fmt;
        pub const render_mode: RenderMode = .full;
        pub const buf_lines: u16 = h; // full-frame for testing

        /// Raw framebuffer in memory
        framebuffer: [fb_size]u8,

        /// Number of times flush was called (for test assertions)
        flush_count: u32,

        /// Last flushed area (for test assertions)
        last_area: ?Area,

        /// Create a new MemDisplay with zeroed framebuffer
        pub fn create() Self {
            return .{
                .framebuffer = [_]u8{0} ** fb_size,
                .flush_count = 0,
                .last_area = null,
            };
        }

        /// Flush callback — copies pixel data to the in-memory framebuffer.
        pub fn flush(self: *Self, area: Area, color_data: [*]const u8) void {
            self.flush_count += 1;
            self.last_area = area;

            // Copy pixel data into the framebuffer line by line
            const area_w = @as(u32, area.width());
            const line_bytes = area_w * @as(u32, bpp);

            var y: u16 = area.y1;
            while (y <= area.y2) : (y += 1) {
                const fb_offset = (@as(u32, y) * @as(u32, w) + @as(u32, area.x1)) * @as(u32, bpp);
                const src_offset = (@as(u32, y - area.y1) * area_w) * @as(u32, bpp);

                if (fb_offset + line_bytes <= fb_size) {
                    const dst = self.framebuffer[fb_offset..][0..line_bytes];
                    const src = color_data[src_offset..][0..line_bytes];
                    @memcpy(dst, src);
                }
            }
        }

        /// Get a raw pixel value at (x, y) as bytes
        pub fn getPixelBytes(self: *const Self, x: u16, y: u16) [bpp]u8 {
            const offset = (@as(u32, y) * @as(u32, w) + @as(u32, x)) * @as(u32, bpp);
            var result: [bpp]u8 = undefined;
            @memcpy(&result, self.framebuffer[offset..][0..bpp]);
            return result;
        }

        /// Check if any pixel in the given area is non-zero
        pub fn hasContent(self: *const Self, area: Area) bool {
            var y: u16 = area.y1;
            while (y <= area.y2) : (y += 1) {
                var x: u16 = area.x1;
                while (x <= area.x2) : (x += 1) {
                    const offset = (@as(u32, y) * @as(u32, w) + @as(u32, x)) * @as(u32, bpp);
                    const end = offset + bpp;
                    if (end <= fb_size) {
                        for (self.framebuffer[offset..end]) |byte| {
                            if (byte != 0) return true;
                        }
                    }
                }
            }
            return false;
        }

        /// Check if the entire framebuffer has any non-zero content
        pub fn hasAnyContent(self: *const Self) bool {
            for (self.framebuffer) |byte| {
                if (byte != 0) return true;
            }
            return false;
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "MemDisplay basic" {
    const Disp = MemDisplay(320, 240, .rgb565);
    var disp = Disp.create();

    try std.testing.expect(!disp.hasAnyContent());
    try std.testing.expectEqual(@as(u32, 0), disp.flush_count);

    var line_data: [320 * 2]u8 = undefined;
    @memset(&line_data, 0xFF);
    disp.flush(.{ .x1 = 0, .y1 = 0, .x2 = 319, .y2 = 0 }, &line_data);

    try std.testing.expectEqual(@as(u32, 1), disp.flush_count);
    try std.testing.expect(disp.hasAnyContent());
    try std.testing.expect(disp.hasContent(.{ .x1 = 0, .y1 = 0, .x2 = 319, .y2 = 0 }));
    try std.testing.expect(!disp.hasContent(.{ .x1 = 0, .y1 = 1, .x2 = 319, .y2 = 1 }));

    const pixel = disp.getPixelBytes(0, 0);
    try std.testing.expectEqual(@as(u8, 0xFF), pixel[0]);
    try std.testing.expectEqual(@as(u8, 0xFF), pixel[1]);
}

test "MemDisplay comptime interface" {
    const Disp = MemDisplay(128, 64, .rgb565);

    // Verify comptime constants match what ui.init() expects
    try std.testing.expectEqual(@as(u16, 128), Disp.width);
    try std.testing.expectEqual(@as(u16, 64), Disp.height);
    try std.testing.expectEqual(ColorFormat.rgb565, Disp.color_format);
    try std.testing.expectEqual(RenderMode.full, Disp.render_mode);
    try std.testing.expectEqual(@as(u16, 64), Disp.buf_lines);

    var disp = Disp.create();
    var data: [128 * 2]u8 = undefined;
    @memset(&data, 0xAB);
    disp.flush(.{ .x1 = 0, .y1 = 0, .x2 = 127, .y2 = 0 }, &data);

    try std.testing.expectEqual(@as(u32, 1), disp.flush_count);
    try std.testing.expect(disp.hasContent(.{ .x1 = 0, .y1 = 0, .x2 = 127, .y2 = 0 }));
}
