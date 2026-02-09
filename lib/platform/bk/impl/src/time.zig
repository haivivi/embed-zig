//! Time Implementation for BK7258
//!
//! Implements trait.time using Armino RTOS delay + AON RTC timestamps.
//!
//! Usage:
//!   const impl = @import("impl");
//!   const trait = @import("trait");
//!   const Time = trait.time.from(impl.Time);

const armino = @import("../../armino/src/armino.zig");

/// Time implementation that satisfies trait.time interface
pub const Time = struct {
    /// Sleep for specified milliseconds
    pub fn sleepMs(ms: u32) void {
        armino.time.sleepMs(ms);
    }

    /// Get current time in milliseconds (since boot)
    pub fn getTimeMs() u64 {
        return armino.time.nowMs();
    }
};

// Re-export utilities
pub const sleepMs = armino.time.sleepMs;
pub const nowMs = armino.time.nowMs;
