//! SAL Time Implementation - FreeRTOS / ESP-IDF
//!
//! Implements sal.time interface using FreeRTOS ticks and ESP timer.

const std = @import("std");

const c = @cImport({
    @cInclude("freertos/FreeRTOS.h");
    @cInclude("freertos/task.h");
    @cInclude("esp_timer.h");
});

/// Sleep for specified milliseconds
pub fn sleepMs(ms: u32) void {
    c.vTaskDelay(ms / c.portTICK_PERIOD_MS);
}

/// Sleep for specified nanoseconds (rounded to tick resolution)
pub fn sleep(ns: u64) void {
    const ms: u32 = @intCast(ns / 1_000_000);
    sleepMs(ms);
}

/// Get current timestamp in microseconds (since boot)
pub fn nowUs() u64 {
    return @intCast(c.esp_timer_get_time());
}

/// Get current timestamp in milliseconds (since boot)
pub fn nowMs() u64 {
    return nowUs() / 1000;
}

/// Get system tick count
pub fn getTicks() u32 {
    return @intCast(c.xTaskGetTickCount());
}

/// Convert milliseconds to ticks
pub fn msToTicks(ms: u32) u32 {
    return ms / c.portTICK_PERIOD_MS;
}

/// Convert ticks to milliseconds
pub fn ticksToMs(ticks: u32) u32 {
    return ticks * c.portTICK_PERIOD_MS;
}

/// Get tick period in milliseconds
pub fn getTickPeriodMs() u32 {
    return c.portTICK_PERIOD_MS;
}

/// Deadline helper for timeout operations
pub const Deadline = struct {
    start_ticks: u32,
    timeout_ticks: u32,

    /// Create deadline from milliseconds
    pub fn fromMs(timeout_ms: u32) Deadline {
        return .{
            .start_ticks = getTicks(),
            .timeout_ticks = msToTicks(timeout_ms),
        };
    }

    /// Check if deadline has passed
    pub fn isExpired(self: Deadline) bool {
        const elapsed = getTicks() -% self.start_ticks;
        return elapsed >= self.timeout_ticks;
    }

    /// Get remaining ticks (0 if expired)
    pub fn remainingTicks(self: Deadline) u32 {
        const elapsed = getTicks() -% self.start_ticks;
        if (elapsed >= self.timeout_ticks) return 0;
        return self.timeout_ticks - elapsed;
    }

    /// Get remaining milliseconds (0 if expired)
    pub fn remainingMs(self: Deadline) u32 {
        return ticksToMs(self.remainingTicks());
    }
};

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
