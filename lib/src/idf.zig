//! ESP-IDF Zig bindings
//!
//! Usage:
//!   const idf = @import("esp_zig").idf;
//!
//!   idf.rtos.delayMs(1000);
//!   const stats = idf.heap.getInternalStats();

pub const heap = @import("heap.zig");
pub const led_strip = @import("led_strip.zig");
pub const LedStrip = led_strip.LedStrip;
pub const log = @import("log.zig");
pub const rtos = @import("rtos.zig");
pub const delayMs = rtos.delayMs;
pub const sys = @import("sys.zig");
pub const EspError = sys.EspError;

// Re-export common types at top level
// Re-export common functions
test {
    @import("std").testing.refAllDecls(@This());
}
