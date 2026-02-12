//! SPI LCD Driver — Platform-Free
//!
//! Generic LCD controller driver that communicates via SPI bus + DC pin.
//! Implements the display surface driver interface (flush, setBacklight).
//!
//! Supports ST7789-compatible LCD controllers (CASET/RASET/RAMWR commands).
//!
//! ## Usage
//!
//! ```zig
//! const display = @import("display");
//!
//! // Board-specific types (from platform layer)
//! const Spi = esp.spi.SpiBus;
//! const DcPin = esp.gpio.OutputPin;
//!
//! const LcdDriver = display.SpiLcd(Spi, DcPin, .{
//!     .width = 240,
//!     .height = 240,
//!     .color_format = .rgb565,
//! });
//!
//! var spi = try Spi.init(.{ .clk = 6, .mosi = 7, .cs = 10 });
//! var dc = try DcPin.init(9);
//! var lcd = LcdDriver.init(&spi, &dc);
//! lcd.flush(area, pixels);
//! ```

const types = @import("types.zig");
pub const Area = types.Area;
pub const ColorFormat = types.ColorFormat;
pub const RenderMode = types.RenderMode;
pub const bytesPerPixel = types.bytesPerPixel;

/// SPI LCD configuration
pub const Config = struct {
    width: u16,
    height: u16,
    color_format: ColorFormat = .rgb565,
    render_mode: RenderMode = .partial,
    buf_lines: u16 = 10,
    /// Column address offset (some displays have non-zero origin)
    col_offset: u16 = 0,
    /// Row address offset
    row_offset: u16 = 0,
};

/// ST7789-compatible commands
const CMD = struct {
    const NOP = 0x00;
    const SWRESET = 0x01;
    const SLPOUT = 0x11;
    const NORON = 0x13;
    const INVON = 0x21;
    const DISPON = 0x29;
    const CASET = 0x2A; // Column Address Set
    const RASET = 0x2B; // Row Address Set
    const RAMWR = 0x2C; // Memory Write
    const COLMOD = 0x3A; // Interface Pixel Format
    const MADCTL = 0x36; // Memory Data Access Control
};

/// Create an SPI LCD driver, generic over SPI bus and DC pin.
///
/// `Spi` must implement: `fn write(self: *Spi, data: []const u8) !void`
/// `DcPin` must implement: `fn setHigh(self: *DcPin) void` and `fn setLow(self: *DcPin) void`
///
/// The returned type satisfies the display surface Driver contract:
/// - `fn flush(self: *@This(), area: Area, color_data: [*]const u8) void`
/// - `fn setBacklight(self: *@This(), brightness: u8) void` (no-op)
///
pub fn SpiLcd(comptime Spi: type, comptime DcPin: type, comptime config: Config) type {
    comptime {
        // Verify SPI has write
        _ = @as(*const fn (*Spi, []const u8) anyerror!void, &Spi.write);
        // Verify DcPin has setHigh/setLow
        _ = @as(*const fn (*DcPin) void, &DcPin.setHigh);
        _ = @as(*const fn (*DcPin) void, &DcPin.setLow);
    }

    const bpp = bytesPerPixel(config.color_format);

    return struct {
        const Self = @This();

        spi: *Spi,
        dc: *DcPin,

        /// SPI error counter — incremented on each failed SPI write.
        /// Upper layers can inspect this for diagnostics (e.g. after flush).
        /// The flush signature must remain `void` (LVGL C callback constraint),
        /// so errors are tracked here instead of propagated.
        spi_errors: u32 = 0,

        /// Display dimensions (compile-time constants for display surface spec)
        pub const width: u16 = config.width;
        pub const height: u16 = config.height;
        pub const color_format: ColorFormat = config.color_format;
        pub const render_mode: RenderMode = config.render_mode;
        pub const buf_lines: u16 = config.buf_lines;

        pub fn init(spi: *Spi, dc: *DcPin) Self {
            return .{ .spi = spi, .dc = dc, .spi_errors = 0 };
        }

        // ================================================================
        // Display Surface Driver Interface
        // ================================================================

        /// Flush pixels to the LCD.
        /// Sends CASET + RASET + RAMWR commands, then pixel data.
        pub fn flush(self: *Self, area: Area, color_data: [*]const u8) void {
            // Set column address (CASET)
            const x1 = area.x1 + config.col_offset;
            const x2 = area.x2 + config.col_offset;
            self.writeCmd(CMD.CASET);
            self.writeData(&.{
                @intCast(x1 >> 8), @intCast(x1 & 0xFF),
                @intCast(x2 >> 8), @intCast(x2 & 0xFF),
            });

            // Set row address (RASET)
            const y1 = area.y1 + config.row_offset;
            const y2 = area.y2 + config.row_offset;
            self.writeCmd(CMD.RASET);
            self.writeData(&.{
                @intCast(y1 >> 8), @intCast(y1 & 0xFF),
                @intCast(y2 >> 8), @intCast(y2 & 0xFF),
            });

            // Write pixel data (RAMWR)
            const pixel_bytes = area.pixelCount() * @as(u32, bpp);
            self.writeCmd(CMD.RAMWR);
            self.writeData(color_data[0..pixel_bytes]);
        }

        /// Backlight control — no-op for SPI LCD.
        /// Board-level code should use a separate GPIO/PWM driver for backlight.
        pub fn setBacklight(_: *Self, _: u8) void {}

        // ================================================================
        // Low-level SPI + DC helpers
        // ================================================================

        /// Send a command byte (DC low)
        fn writeCmd(self: *Self, cmd: u8) void {
            self.dc.setLow();
            self.spi.write(&.{cmd}) catch {
                self.spi_errors += 1;
            };
        }

        /// Send data bytes (DC high)
        fn writeData(self: *Self, data: []const u8) void {
            self.dc.setHigh();
            self.spi.write(data) catch {
                self.spi_errors += 1;
            };
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

/// Mock SPI that records all bytes written, tagged with DC level
const MockSpi = struct {
    const Entry = struct {
        data: [256]u8,
        len: usize,
        is_cmd: bool, // DC was low (command) when written
    };

    dc: *MockDcPin,
    log: [32]Entry = undefined,
    log_count: usize = 0,

    pub fn write(self: *MockSpi, data: []const u8) !void {
        if (self.log_count < 32) {
            var entry = Entry{ .data = undefined, .len = data.len, .is_cmd = !self.dc.is_data };
            const copy_len = @min(data.len, 256);
            @memcpy(entry.data[0..copy_len], data[0..copy_len]);
            self.log[self.log_count] = entry;
            self.log_count += 1;
        }
    }
};

const MockDcPin = struct {
    is_data: bool = true,
    toggle_count: u32 = 0,

    pub fn setHigh(self: *MockDcPin) void {
        self.is_data = true;
        self.toggle_count += 1;
    }

    pub fn setLow(self: *MockDcPin) void {
        self.is_data = false;
        self.toggle_count += 1;
    }
};

test "SpiLcd flush sends CASET + RASET + RAMWR" {
    var dc = MockDcPin{};
    var spi = MockSpi{ .dc = &dc };

    const Lcd = SpiLcd(MockSpi, MockDcPin, .{
        .width = 240,
        .height = 240,
    });

    var lcd = Lcd.init(&spi, &dc);

    // Flush a 10x10 area
    var pixels: [10 * 10 * 2]u8 = undefined;
    @memset(&pixels, 0xAB);
    lcd.flush(.{ .x1 = 0, .y1 = 0, .x2 = 9, .y2 = 9 }, &pixels);

    // Should have 6 SPI writes: cmd, data, cmd, data, cmd, data
    try std.testing.expectEqual(@as(usize, 6), spi.log_count);

    // CASET command
    try std.testing.expect(spi.log[0].is_cmd);
    try std.testing.expectEqual(@as(u8, CMD.CASET), spi.log[0].data[0]);

    // CASET data: x1=0, x2=9
    try std.testing.expect(!spi.log[1].is_cmd);
    try std.testing.expectEqual(@as(usize, 4), spi.log[1].len);
    try std.testing.expectEqual(@as(u8, 0), spi.log[1].data[0]); // x1 high
    try std.testing.expectEqual(@as(u8, 0), spi.log[1].data[1]); // x1 low
    try std.testing.expectEqual(@as(u8, 0), spi.log[1].data[2]); // x2 high
    try std.testing.expectEqual(@as(u8, 9), spi.log[1].data[3]); // x2 low

    // RASET command
    try std.testing.expect(spi.log[2].is_cmd);
    try std.testing.expectEqual(@as(u8, CMD.RASET), spi.log[2].data[0]);

    // RASET data: y1=0, y2=9
    try std.testing.expect(!spi.log[3].is_cmd);

    // RAMWR command
    try std.testing.expect(spi.log[4].is_cmd);
    try std.testing.expectEqual(@as(u8, CMD.RAMWR), spi.log[4].data[0]);

    // Pixel data
    try std.testing.expect(!spi.log[5].is_cmd);
    try std.testing.expectEqual(@as(usize, 10 * 10 * 2), spi.log[5].len);
}

test "SpiLcd with column/row offset" {
    var dc = MockDcPin{};
    var spi = MockSpi{ .dc = &dc };

    const Lcd = SpiLcd(MockSpi, MockDcPin, .{
        .width = 240,
        .height = 240,
        .col_offset = 80, // Some displays have offset
        .row_offset = 0,
    });

    var lcd = Lcd.init(&spi, &dc);

    var pixels: [1 * 1 * 2]u8 = undefined;
    lcd.flush(.{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0 }, &pixels);

    // CASET data should include offset: x1=80, x2=80
    try std.testing.expectEqual(@as(u8, 0), spi.log[1].data[0]); // high byte
    try std.testing.expectEqual(@as(u8, 80), spi.log[1].data[1]); // low byte = offset
    try std.testing.expectEqual(@as(u8, 0), spi.log[1].data[2]); // high byte
    try std.testing.expectEqual(@as(u8, 80), spi.log[1].data[3]); // low byte = offset
}

test "SpiLcd compile-time properties" {
    const Lcd = SpiLcd(MockSpi, MockDcPin, .{
        .width = 320,
        .height = 240,
        .color_format = .rgb565,
        .render_mode = .partial,
        .buf_lines = 20,
    });

    try std.testing.expectEqual(@as(u16, 320), Lcd.width);
    try std.testing.expectEqual(@as(u16, 240), Lcd.height);
    try std.testing.expectEqual(ColorFormat.rgb565, Lcd.color_format);
    try std.testing.expectEqual(RenderMode.partial, Lcd.render_mode);
    try std.testing.expectEqual(@as(u16, 20), Lcd.buf_lines);
}
