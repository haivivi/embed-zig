//! Display — Platform-Free Display Package
//!
//! Provides display types and LCD controller drivers.
//! No hardware dependency — uses trait interfaces (SPI, GPIO) injected at comptime.
//!
//! ## Architecture
//!
//! ```
//! ┌─────────────────────────────────────────┐
//! │ lib/pkg/ui (LVGL)                       │
//! │   ui.init(Driver, &driver)              │
//! ├─────────────────────────────────────────┤
//! │ lib/pkg/display                         │
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
//! // Use directly with ui.init() — no wrapper needed
//! var lcd = LcdDriver.init(&spi, &dc);
//! var ctx = try ui.init(LcdDriver, &lcd);
//! ```

// Types
pub const Area = @import("types.zig").Area;
pub const ColorFormat = @import("types.zig").ColorFormat;
pub const RenderMode = @import("types.zig").RenderMode;
pub const bytesPerPixel = @import("types.zig").bytesPerPixel;

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
    _ = @import("spi_lcd.zig");
    _ = @import("mem_display.zig");
}
