//! Icon — 1-bit bitmap loading and rendering
//!
//! .icon file format:
//!   byte 0: width (u8)
//!   byte 1: height (u8)
//!   byte 2...: 1-bit bitmap (ceil(w/8) * h bytes, MSB first, row-major)

pub const Icon = struct {
    width: u8,
    height: u8,
    data: []const u8,

    pub fn fromData(data: []const u8) ?Icon {
        if (data.len < 2) return null;
        const w = data[0];
        const h = data[1];
        if (w == 0 or h == 0) return null;
        const expected = @as(usize, (w + 7) / 8) * h;
        if (data.len < 2 + expected) return null;
        return .{ .width = w, .height = h, .data = data[2 .. 2 + expected] };
    }

    pub fn bytesPerRow(self: *const Icon) usize {
        return (@as(usize, self.width) + 7) / 8;
    }

    pub fn getPixel(self: *const Icon, x: u8, y: u8) bool {
        if (x >= self.width or y >= self.height) return false;
        const byte_idx = @as(usize, y) * self.bytesPerRow() + @as(usize, x) / 8;
        if (byte_idx >= self.data.len) return false;
        const bit = @as(u8, 0x80) >> @intCast(x % 8);
        return self.data[byte_idx] & bit != 0;
    }

    pub fn pixelCount(self: *const Icon) u32 {
        var count: u32 = 0;
        for (self.data) |byte| {
            var b = byte;
            while (b != 0) {
                count += @as(u32, b & 1);
                b >>= 1;
            }
        }
        return count;
    }

    pub fn draw(self: *const Icon, fb: anytype, x: u16, y: u16, color: u16) void {
        const bpr = self.bytesPerRow();
        var row: u16 = 0;
        while (row < self.height) : (row += 1) {
            var col: u16 = 0;
            while (col < self.width) : (col += 1) {
                const byte_idx = @as(usize, row) * bpr + @as(usize, col) / 8;
                if (byte_idx >= self.data.len) continue;
                const bit = @as(u8, 0x80) >> @intCast(col % 8);
                if (self.data[byte_idx] & bit != 0) {
                    fb.setPixel(x + col, y + row, color);
                }
            }
        }
    }
};
