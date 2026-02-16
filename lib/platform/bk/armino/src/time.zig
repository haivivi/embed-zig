//! Armino SDK Time Utilities
//!
//! Provides sleep and timestamp functions using Armino RTOS and AON RTC.

// C helper functions (defined in bk_zig_helper.c)
extern fn bk_zig_delay_ms(ms: u32) void;
extern fn bk_zig_get_time_ms() u64;

/// Sleep for specified milliseconds
pub fn sleepMs(ms: u32) void {
    bk_zig_delay_ms(ms);
}

/// Get current timestamp in milliseconds (since boot, from AON RTC)
pub fn nowMs() u64 {
    return bk_zig_get_time_ms();
}
