//! Time Implementation for ESP32
//!
//! Implements trait.time using idf.time (FreeRTOS + esp_timer).
//!
//! Usage:
//!   const impl = @import("impl");
//!   const trait = @import("trait");
//!   const Time = trait.time.from(impl.Time);

const idf = @import("idf");

/// Time implementation that satisfies trait.time interface
pub const Time = struct {
    /// Sleep for specified milliseconds
    pub fn sleepMs(ms: u32) void {
        idf.time.sleepMs(ms);
    }

    /// Get current time in milliseconds (since boot)
    pub fn nowMs() u64 {
        return idf.time.nowMs();
    }
};

// Re-export additional time utilities
pub const sleepMs = idf.time.sleepMs;
pub const nowMs = idf.time.nowMs;
pub const nowUs = idf.time.nowUs;
pub const Deadline = idf.time.Deadline;
pub const Stopwatch = idf.time.Stopwatch;
