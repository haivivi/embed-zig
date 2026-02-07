//! ESP-IDF Event Loop
//!
//! Manages the default event loop which is the foundation for
//! all event-driven components (WiFi, Net, BLE, etc.)
//!
//! Usage:
//!   const event = @import("event.zig");
//!   try event.init();
//!   defer event.deinit();

const c = @cImport({
    @cInclude("event_helper.h");
});

pub const Error = error{
    InitFailed,
};

/// Initialize the default event loop (idempotent)
/// Safe to call multiple times - will only create once
pub fn init() Error!void {
    if (c.event_helper_init() != 0) {
        return error.InitFailed;
    }
}

/// Deinitialize the default event loop
pub fn deinit() void {
    c.event_helper_deinit();
}

/// Check if event loop is initialized
pub fn isInitialized() bool {
    return c.event_helper_is_initialized();
}
