//! Display — Platform-Free Display Package
//!
//! Provides display types, surface wrapper, and LCD controller drivers.
//! No hardware dependency — uses trait interfaces (SPI, GPIO) injected at comptime.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ lib/pkg/ui (LVGL)                       │
//! │   ui.init(Display, &display)            │
//! ├─────────────────────────────────────────┤
//! │ lib/pkg/display                         │
//! │   display.from(spec) — surface wrapper  │
//! │   display.SpiLcd(Spi, Dc, cfg) — driver │
//! │   display.MemDisplay(w, h, fmt) — test  │
//! ├─────────────────────────────────────────┤
//! │ lib/trait/spi — SPI bus contract        │
//! │ Platform GPIO — DC pin control          │
//! ├─────────────────────────────────────────┤
//! │ lib/platform/{esp,websim}/spi — impl    │
//! └─────────────────────────────────────────┘
//! ```
//!
//! ## Usage
//!
//! ```zig
//! const display = @import("display");
//!
//! // Create SPI LCD driver (platform-free, generic over SPI + DC pin)
//! const LcdDriver = display.SpiLcd(board.Spi, board.DcPin, .{
//!     .width = 240,
//!     .height = 240,
//!     .color_format = .rgb565,
//! });
//!
//! // Wrap in display surface for LVGL
//! const Display = display.from(struct {
//!     pub const Driver = LcdDriver;
//!     pub const width: u16 = LcdDriver.width;
//!     pub const height: u16 = LcdDriver.height;
//!     pub const color_format = LcdDriver.color_format;
//!     pub const render_mode = LcdDriver.render_mode;
//!     pub const buf_lines: u16 = LcdDriver.buf_lines;
//!     pub const meta = .{ .id = "display.main" };
//! });
//! ```

// Types
pub const Area = @import("types.zig").Area;
pub const ColorFormat = @import("types.zig").ColorFormat;
pub const RenderMode = @import("types.zig").RenderMode;
pub const bytesPerPixel = @import("types.zig").bytesPerPixel;

// Surface wrapper (compile-time validated display abstraction)
pub const from = @import("surface.zig").from;
pub const is = @import("surface.zig").is;

// LCD controller drivers
pub const SpiLcd = @import("spi_lcd.zig").SpiLcd;
pub const SpiLcdConfig = @import("spi_lcd.zig").Config;

// Test utilities
pub const MemDisplay = @import("mem_display.zig").MemDisplay;

// ============================================================================
// Tests
// ============================================================================

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = @import("types.zig");
    _ = @import("surface.zig");
    _ = @import("spi_lcd.zig");
    _ = @import("mem_display.zig");
}
