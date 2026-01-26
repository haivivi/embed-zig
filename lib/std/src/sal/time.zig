//! SAL Time Implementation - Zig std
//!
//! Implements sal.time interface using std.time.

const std = @import("std");

/// Sleep for specified milliseconds
pub fn sleepMs(ms: u32) void {
    std.Thread.sleep(@as(u64, ms) * std.time.ns_per_ms);
}

/// Sleep for specified nanoseconds
pub fn sleep(ns: u64) void {
    std.Thread.sleep(ns);
}

/// Get current timestamp in microseconds (since some epoch)
pub fn nowUs() u64 {
    return @intCast(std.time.microTimestamp());
}

/// Get current timestamp in milliseconds (since some epoch)
pub fn nowMs() u64 {
    return @intCast(std.time.milliTimestamp());
}

/// Stopwatch for measuring elapsed time
pub const Stopwatch = struct {
    start_us: u64,

    /// Start stopwatch
    pub fn start() Stopwatch {
        return .{ .start_us = nowUs() };
    }

    /// Get elapsed microseconds
    pub fn elapsedUs(self: Stopwatch) u64 {
        return nowUs() - self.start_us;
    }

    /// Get elapsed milliseconds
    pub fn elapsedMs(self: Stopwatch) u64 {
        return self.elapsedUs() / 1000;
    }

    /// Reset stopwatch
    pub fn reset(self: *Stopwatch) void {
        self.start_us = nowUs();
    }

    /// Lap: get elapsed and reset
    pub fn lap(self: *Stopwatch) u64 {
        const elapsed = self.elapsedUs();
        self.reset();
        return elapsed;
    }
};

test "sleepMs" {
    const start = nowMs();
    sleepMs(10);
    const elapsed = nowMs() - start;
    try std.testing.expect(elapsed >= 10);
}

test "Stopwatch" {
    var sw = Stopwatch.start();
    sleepMs(5);
    const elapsed = sw.elapsedMs();
    try std.testing.expect(elapsed >= 5);
}
