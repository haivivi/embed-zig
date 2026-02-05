//! Time - macOS std.time Implementation

const std = @import("std");

/// Get current time in milliseconds (monotonic)
pub fn getTimeMs() u64 {
    return @intCast(@divFloor(std.time.nanoTimestamp(), std.time.ns_per_ms));
}

/// Sleep for milliseconds
pub fn sleepMs(ms: u32) void {
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
}
