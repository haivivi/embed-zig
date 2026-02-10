//! Display Hardware Abstraction Layer
//!
//! Provides a platform-independent interface for LCD/framebuffer displays.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ Application / UI Framework (LVGL)       │
//! │   ui.init(board.display)                │
//! ├─────────────────────────────────────────┤
//! │ Display(spec)  ← HAL wrapper            │
//! │   - resolution, color format            │
//! │   - flush callback for UI frameworks    │
//! │   - backlight control                   │
//! ├─────────────────────────────────────────┤
//! │ Driver (spec.Driver)  ← platform impl   │
//! │   - flush(area, color_data)             │
//! │   - setBacklight(brightness)            │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const display_spec = struct {
//!     pub const Driver = SpiLcdDriver;
//!     pub const width = 320;
//!     pub const height = 240;
//!     pub const color_format = .rgb565;
//!     pub const meta = .{ .id = "display.main" };
//! };
//!
//! const MyDisplay = hal.display.from(display_spec);
//! var display = MyDisplay.init(&driver_instance);
//!
//! display.flush(area, color_data);
//! display.setBacklight(200);
//! ```

const std = @import("std");

// ============================================================================
// Types
// ============================================================================

/// Color format of the display framebuffer
pub const ColorFormat = enum {
    rgb565, // 16-bit, 2 bytes per pixel — most common for embedded
    rgb888, // 24-bit, 3 bytes per pixel
    xrgb8888, // 32-bit, 4 bytes per pixel (X channel ignored)
    argb8888, // 32-bit, 4 bytes per pixel with alpha
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
// Display HAL Component
// ============================================================================

/// Create Display HAL component from spec.
///
/// spec must define:
/// - `Driver`: struct with `flush` method
/// - `width`: comptime u16 — horizontal resolution
/// - `height`: comptime u16 — vertical resolution
/// - `color_format`: ColorFormat — pixel format
/// - `meta`: .{ .id = "..." }
///
/// Driver required methods:
/// - `fn flush(self: *Driver, area: Area, color_data: [*]const u8) void`
///
/// Driver optional methods:
/// - `fn setBacklight(self: *Driver, brightness: u8) void`
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

test "Display with mock driver" {
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

    // Verify compile-time properties
    try std.testing.expectEqual(@as(u16, 320), TestDisplay.width);
    try std.testing.expectEqual(@as(u16, 240), TestDisplay.height);
    try std.testing.expectEqual(ColorFormat.rgb565, TestDisplay.color_format);
    try std.testing.expectEqual(@as(u8, 2), TestDisplay.bpp);
    try std.testing.expectEqual(@as(u32, 320 * 240), TestDisplay.totalPixels());
    try std.testing.expectEqual(@as(u32, 320 * 240 * 2), TestDisplay.framebufferSize());
    try std.testing.expectEqualStrings("display.test", TestDisplay.meta.id);

    // Test flush
    const area = Area{ .x1 = 0, .y1 = 0, .x2 = 319, .y2 = 0 };
    var buf: [320 * 2]u8 = undefined;
    display.flush(area, &buf);
    try std.testing.expectEqual(@as(u32, 1), driver.flush_count);
    try std.testing.expectEqual(@as(u16, 0), driver.last_area.?.x1);
    try std.testing.expectEqual(@as(u16, 319), driver.last_area.?.x2);

    // Test backlight
    display.setBacklight(200);
    try std.testing.expectEqual(@as(u8, 200), driver.backlight);
}

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

test "Display without backlight" {
    const MinimalDriver = struct {
        flush_count: u32 = 0,

        pub fn flush(self: *@This(), _: Area, _: [*]const u8) void {
            self.flush_count += 1;
        }
        // No setBacklight — should still compile
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

    // setBacklight should be no-op
    display.setBacklight(100);

    // flush should work
    var buf: [128 * 2]u8 = undefined;
    display.flush(.{ .x1 = 0, .y1 = 0, .x2 = 127, .y2 = 0 }, &buf);
    try std.testing.expectEqual(@as(u32, 1), driver.flush_count);
}
