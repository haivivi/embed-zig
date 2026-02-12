//! Display Surface
//!
//! Compile-time validated display wrapper. Creates a uniform interface
//! over any display driver (SPI LCD, RGB panel, memory display, etc.).
//!
//! ## Usage
//!
//! ```zig
//! const display = @import("display");
//!
//! // SPI LCD — partial mode (default)
//! const spi_display_spec = struct {
//!     pub const Driver = SpiLcdDriver;
//!     pub const width: u16 = 320;
//!     pub const height: u16 = 240;
//!     pub const color_format = .rgb565;
//!     pub const render_mode = .partial;
//!     pub const buf_lines: u16 = 20;
//!     pub const meta = .{ .id = "display.main" };
//! };
//!
//! const MyDisplay = display.from(spi_display_spec);
//! var d = MyDisplay.init(&driver);
//! d.flush(area, pixels);
//! ```

const types = @import("types.zig");
pub const Area = types.Area;
pub const ColorFormat = types.ColorFormat;
pub const RenderMode = types.RenderMode;
pub const bytesPerPixel = types.bytesPerPixel;

// ============================================================================
// Type Marker (for hal.Board identification)
// ============================================================================

const _DisplayMarker = struct {};

/// Check if a type is a Display peripheral (for hal.Board)
pub fn is(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "_hal_marker")) return false;
    return T._hal_marker == _DisplayMarker;
}

// ============================================================================
// Display Surface
// ============================================================================

/// Create Display surface from spec.
///
/// spec must define:
/// - `Driver`: struct with `flush` method
/// - `width`: comptime u16 — horizontal resolution
/// - `height`: comptime u16 — vertical resolution
/// - `color_format`: ColorFormat — pixel format
/// - `meta`: .{ .id = "..." }
///
/// spec optional:
/// - `render_mode`: RenderMode — default `.partial`
/// - `buf_lines`: u16 — draw buffer height for partial mode (default 10)
///
/// Driver required methods:
/// - `fn flush(self: *Driver, area: Area, color_data: [*]const u8) void`
///
/// Driver optional methods:
/// - `fn setBacklight(self: *Driver, brightness: u8) void`
/// - `fn getFramebuffer(self: *Driver) [*]u8` — required for `.direct` mode
///
pub fn from(comptime spec: type) type {
    comptime {
        // Verify Driver.flush signature
        _ = @as(*const fn (*spec.Driver, Area, [*]const u8) void, &spec.Driver.flush);
        // Verify resolution and format
        _ = @as(u16, spec.width);
        _ = @as(u16, spec.height);
        _ = @as(ColorFormat, spec.color_format);
        // Verify meta.id
        _ = @as([]const u8, spec.meta.id);
    }

    // Read render_mode (default: partial)
    const mode: RenderMode = if (@hasDecl(spec, "render_mode")) spec.render_mode else .partial;

    // Compute buf_lines based on render mode
    const computed_buf_lines: u16 = switch (mode) {
        .partial => if (@hasDecl(spec, "buf_lines")) spec.buf_lines else 10,
        .full => spec.height,
        .direct => 0, // not used — buffer comes from driver
    };

    // For direct mode, verify Driver has getFramebuffer
    if (mode == .direct) {
        comptime {
            _ = @as(*const fn (*spec.Driver) [*]u8, &spec.Driver.getFramebuffer);
        }
    }

    const Driver = spec.Driver;
    return struct {
        const Self = @This();

        /// Type marker for hal.Board identification
        pub const _hal_marker = _DisplayMarker;

        /// Exported types for hal.Board to access
        pub const DriverType = Driver;

        // ================================================================
        // Metadata
        // ================================================================

        /// Component metadata
        pub const meta = spec.meta;

        /// Display resolution (compile-time constants)
        pub const width: u16 = spec.width;
        pub const height: u16 = spec.height;

        /// Color format
        pub const color_format: ColorFormat = spec.color_format;

        /// Bytes per pixel
        pub const bpp: u8 = bytesPerPixel(spec.color_format);

        /// Render mode — determines how UI framework manages draw buffers
        pub const render_mode: RenderMode = mode;

        /// Draw buffer height in lines (comptime).
        /// - partial: configured via spec.buf_lines (default 10)
        /// - full: equals height (full frame)
        /// - direct: 0 (buffer from driver)
        pub const buf_lines: u16 = computed_buf_lines;

        /// The underlying driver instance
        driver: *Driver,

        /// Initialize with a driver instance
        pub fn init(driver: *Driver) Self {
            return .{ .driver = driver };
        }

        // ----- Core Display Operations -----

        /// Flush pixel data to the display.
        /// `area` defines the rectangular region.
        /// `color_data` is a pointer to the raw pixel bytes
        /// (length = area.pixelCount() * bpp).
        pub fn flush(self: *Self, area: Area, color_data: [*]const u8) void {
            self.driver.flush(area, color_data);
        }

        // ----- Backlight Control -----

        /// Set backlight brightness (0-255).
        /// No-op if driver doesn't support backlight control.
        pub fn setBacklight(self: *Self, brightness: u8) void {
            if (@hasDecl(Driver, "setBacklight")) {
                self.driver.setBacklight(brightness);
            }
        }

        // ----- Convenience -----

        /// Total number of pixels
        pub fn totalPixels() u32 {
            return @as(u32, width) * @as(u32, height);
        }

        /// Total framebuffer size in bytes
        pub fn framebufferSize() u32 {
            return totalPixels() * @as(u32, bpp);
        }
    };
}

// ============================================================================
// Tests
// ============================================================================

const std = @import("std");

test "Display with mock driver — default partial mode" {
    const MockDriver = struct {
        flush_count: u32 = 0,
        last_area: ?Area = null,
        backlight: u8 = 0,

        pub fn flush(self: *@This(), area: Area, _: [*]const u8) void {
            self.flush_count += 1;
            self.last_area = area;
        }

        pub fn setBacklight(self: *@This(), brightness: u8) void {
            self.backlight = brightness;
        }
    };

    const display_spec = struct {
        pub const Driver = MockDriver;
        pub const width: u16 = 320;
        pub const height: u16 = 240;
        pub const color_format: ColorFormat = .rgb565;
        pub const meta = .{ .id = "display.test" };
    };

    const TestDisplay = from(display_spec);

    var driver = MockDriver{};
    var display = TestDisplay.init(&driver);

    try std.testing.expectEqual(@as(u16, 320), TestDisplay.width);
    try std.testing.expectEqual(@as(u16, 240), TestDisplay.height);
    try std.testing.expectEqual(ColorFormat.rgb565, TestDisplay.color_format);
    try std.testing.expectEqual(@as(u8, 2), TestDisplay.bpp);
    try std.testing.expectEqual(@as(u32, 320 * 240), TestDisplay.totalPixels());
    try std.testing.expectEqual(@as(u32, 320 * 240 * 2), TestDisplay.framebufferSize());
    try std.testing.expectEqualStrings("display.test", TestDisplay.meta.id);

    try std.testing.expectEqual(RenderMode.partial, TestDisplay.render_mode);
    try std.testing.expectEqual(@as(u16, 10), TestDisplay.buf_lines);

    const area = Area{ .x1 = 0, .y1 = 0, .x2 = 319, .y2 = 0 };
    var buf: [320 * 2]u8 = undefined;
    display.flush(area, &buf);
    try std.testing.expectEqual(@as(u32, 1), driver.flush_count);

    display.setBacklight(200);
    try std.testing.expectEqual(@as(u8, 200), driver.backlight);
}

test "Display partial mode with custom buf_lines" {
    const MockDriver = struct {
        pub fn flush(_: *@This(), _: Area, _: [*]const u8) void {}
    };

    const spec = struct {
        pub const Driver = MockDriver;
        pub const width: u16 = 240;
        pub const height: u16 = 240;
        pub const color_format: ColorFormat = .rgb565;
        pub const render_mode: RenderMode = .partial;
        pub const buf_lines: u16 = 20;
        pub const meta = .{ .id = "display.spi" };
    };

    const Disp = from(spec);
    try std.testing.expectEqual(RenderMode.partial, Disp.render_mode);
    try std.testing.expectEqual(@as(u16, 20), Disp.buf_lines);
}

test "Display full mode — buf_lines equals height" {
    const MockDriver = struct {
        pub fn flush(_: *@This(), _: Area, _: [*]const u8) void {}
    };

    const spec = struct {
        pub const Driver = MockDriver;
        pub const width: u16 = 240;
        pub const height: u16 = 240;
        pub const color_format: ColorFormat = .rgb565;
        pub const render_mode: RenderMode = .full;
        pub const meta = .{ .id = "display.sim" };
    };

    const Disp = from(spec);
    try std.testing.expectEqual(RenderMode.full, Disp.render_mode);
    try std.testing.expectEqual(@as(u16, 240), Disp.buf_lines);
}

test "Display direct mode — requires getFramebuffer" {
    const RgbDriver = struct {
        var fb: [480 * 272 * 2]u8 = undefined;

        pub fn flush(_: *@This(), _: Area, _: [*]const u8) void {}
        pub fn getFramebuffer(_: *@This()) [*]u8 {
            return &fb;
        }
    };

    const spec = struct {
        pub const Driver = RgbDriver;
        pub const width: u16 = 480;
        pub const height: u16 = 272;
        pub const color_format: ColorFormat = .rgb565;
        pub const render_mode: RenderMode = .direct;
        pub const meta = .{ .id = "display.rgb" };
    };

    const Disp = from(spec);
    try std.testing.expectEqual(RenderMode.direct, Disp.render_mode);
    try std.testing.expectEqual(@as(u16, 0), Disp.buf_lines);
}

test "Display without backlight" {
    const MinimalDriver = struct {
        flush_count: u32 = 0,

        pub fn flush(self: *@This(), _: Area, _: [*]const u8) void {
            self.flush_count += 1;
        }
    };

    const spec = struct {
        pub const Driver = MinimalDriver;
        pub const width: u16 = 128;
        pub const height: u16 = 64;
        pub const color_format: ColorFormat = .rgb565;
        pub const meta = .{ .id = "display.minimal" };
    };

    const TestDisplay = from(spec);

    var driver = MinimalDriver{};
    var display = TestDisplay.init(&driver);

    display.setBacklight(100);

    var buf: [128 * 2]u8 = undefined;
    display.flush(.{ .x1 = 0, .y1 = 0, .x2 = 127, .y2 = 0 }, &buf);
    try std.testing.expectEqual(@as(u32, 1), driver.flush_count);
}
