//! Time and Delay Functions
//!
//! Cross-platform time-related abstractions:
//! - Sleep/delay
//! - Timestamp/tick counter
//! - Timer utilities

const std = @import("std");

/// Sleep for specified duration
pub fn sleep(ns: u64) void {
    _ = ns;
    @compileError("sal.time.sleep requires platform implementation");
}

/// Sleep for specified milliseconds
pub fn sleepMs(ms: u32) void {
    _ = ms;
    @compileError("sal.time.sleepMs requires platform implementation");
}

/// Get current timestamp in microseconds
pub fn nowUs() u64 {
    @compileError("sal.time.nowUs requires platform implementation");
}

/// Get current timestamp in milliseconds
pub fn nowMs() u64 {
    @compileError("sal.time.nowMs requires platform implementation");
}

/// Get system tick count (platform-specific resolution)
pub fn getTicks() u32 {
    @compileError("sal.time.getTicks requires platform implementation");
}

/// Convert milliseconds to ticks
pub fn msToTicks(ms: u32) u32 {
    _ = ms;
    @compileError("sal.time.msToTicks requires platform implementation");
}

/// Convert ticks to milliseconds
pub fn ticksToMs(ticks: u32) u32 {
    _ = ticks;
    @compileError("sal.time.ticksToMs requires platform implementation");
}
